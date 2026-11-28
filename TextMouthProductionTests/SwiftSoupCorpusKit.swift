import Foundation
import SwiftSoup

// The pieces the SwiftSoup corpus checks share: `SwiftSoupCorpusTests` (the
// hosted test) and `Scripts/test/swiftsoup-corpus/` (the Release-build
// comparison made when SwiftSoup is upgraded) compile this one file, so both
// damage a document in the same places and summarise a tree in the same way.
// It names SwiftSoup and Foundation only, never the app, so the script can
// build it alone.
//
// What it is for: Vendor/SwiftSoup holds a copy of SwiftSoup that must build
// exactly the trees the released package builds. A checksum of a tree, kept
// from the released package, is the proof for a copy.

/// FNV-1a over 64 bits: a checksum of the bytes of every string added to it.
struct SoupChecksum {
    /// The running value, started at FNV's offset basis.
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    /// Mixes `text`'s UTF-8 bytes in, then a separator byte no UTF-8 text
    /// holds, so that adding "ab" then "c" differs from adding "a" then "bc".
    mutating func add(_ text: String) {
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        value = (value ^ 0xff) &* 0x0000_0100_0000_01b3
    }

    /// The value as sixteen lowercase hex digits.
    var hex: String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// The checksum of one string alone.
    static func of(_ text: String) -> UInt64 {
        var sum = SoupChecksum()
        sum.add(text)
        return sum.value
    }
}

/// A small deterministic generator (xorshift64*), so every run, on every
/// machine and with either SwiftSoup, damages a document in the same places.
struct SoupDamage {
    /// The generator's state; never zero.
    private var state: UInt64

    /// A generator for the document named `key`: seeded from the checksum of
    /// its name, so adding or removing another document never moves the
    /// damage done to this one.
    init(key: String) {
        state = SoupChecksum.of(key) | 1
    }

    /// The next value below `bound` (a bound below 1 reads as 1).
    mutating func next(below bound: Int) -> Int {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Int((state &* 0x2545_F491_4F6C_DD1D) >> 33) % max(bound, 1)
    }
}

/// Everything the corpus checks do that needs no test framework.
enum SoupCorpusKit {
    /// Markup that sends an HTML tree builder down its recovery paths when it
    /// lands in the middle of a document: unclosed and misnested formatting,
    /// table and select contexts, foreign content, broken character
    /// references, and half comments.
    static let intruders: [String] = [
        "<b>", "</b>", "<i>", "</i>", "<p>", "</p>", "<li>", "</div>", "<table>", "<tr>", "<td>", "</table>",
        "<select>", "<option>", "<form>", "</form>", "<svg>", "<math>", "<template>", "</body>", "</html>",
        "<frameset>", "<!--", "-->", "<![CDATA[", "]]>", "&amp", "&#150;", "&notit;", "&#x110000;", "<a href='x'>",
        "<h1>", "</h2>", "<br/>", "<script>", "</script>", "<style>", "<title>", "<pre>\n", "<", ">", "\"", "'", "\u{0}"
    ]

    /// `bytes` damaged in three places, each of them one of: a range deleted,
    /// a range repeated, or an intruder inserted, at positions `damage` picks.
    static func damaged(_ bytes: [UInt8], _ damage: inout SoupDamage) -> [UInt8] {
        var result = bytes
        for _ in 0..<3 {
            guard result.count > 8 else { break }
            let at = damage.next(below: result.count - 4)
            let length = min(1 + damage.next(below: 40), result.count - at)
            switch damage.next(below: 3) {
            case 0: result.removeSubrange(at..<(at + length))
            case 1: result.insert(contentsOf: Array(result[at..<(at + length)]), at: at)
            default: result.insert(contentsOf: Array(intruders[damage.next(below: intruders.count)].utf8), at: at)
            }
        }
        return result
    }

    /// Adds to `sum` every node under `node`, in document order, as the app's
    /// converters see it: each element's name and every attribute (in the
    /// order SwiftSoup keeps them), each text node's whole text, each data
    /// node's data (a script's or style's content), each comment, and each
    /// declaration. A letter before each says which kind it is.
    static func walk(_ node: Node, into sum: inout SoupChecksum) {
        for child in node.getChildNodes() {
            if let element = child as? Element {
                sum.add("E" + element.tagName())
                for attribute in element.getAttributes()?.asList() ?? [] {
                    sum.add(attribute.getKey())
                    sum.add(attribute.getValue())
                }
                walk(element, into: &sum)
                sum.add("/")
            } else if let text = child as? TextNode {
                sum.add("T" + text.getWholeText())
            } else if let data = child as? DataNode {
                sum.add("D" + data.getWholeData())
            } else if let comment = child as? Comment {
                sum.add("C" + comment.getData())
            } else if let declaration = child as? XmlDeclaration {
                sum.add("X" + declaration.name())
                sum.add((try? declaration.getWholeDeclaration()) ?? "")
            } else {
                // A document type, or any kind added later: its markup.
                sum.add("O" + ((try? child.outerHtml()) ?? ""))
            }
        }
    }

    /// The summary of `document`: sixteen hex digits that cover the tree walk,
    /// `text()`, `outerHtml()`, and `title()`. Two documents with the same
    /// summary have the same tree, the same words, and the same markup.
    static func summary(of document: Document) throws -> String {
        var sum = SoupChecksum()
        walk(document, into: &sum)
        sum.add(try document.text())
        sum.add(try document.outerHtml())
        sum.add(try document.title())
        return sum.hex
    }

    /// The text `bytes` hold, as every parse of the corpus reads it: UTF-8,
    /// each invalid sequence read as U+FFFD.
    static func markup(of bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The summary of the document `parse` makes, or "refused" when it throws
    /// (the app refuses some input before SwiftSoup sees it, and SwiftSoup
    /// itself throws on some), so a refusal is part of the record too.
    static func outcome(_ parse: () throws -> Document) -> String {
        do {
            return try summary(of: try parse())
        } catch {
            return "refused"
        }
    }
}
