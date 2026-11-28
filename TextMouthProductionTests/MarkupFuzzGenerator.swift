import Foundation

/// Random markup, made to walk through every rule of SwiftSoup's tokeniser and
/// tree builder rather than to look like a book, for holding `MarkupGuard`'s
/// pass against the parser. A round's document depends only on its seed and
/// round, so the rounds a test reads can first be proved safe in a harness that
/// can catch a trap, which a test host cannot.
enum MarkupFuzzGenerator {

    /// A repeatable sequence of numbers (SplitMix64).
    struct Numbers {
        var state: UInt64

        /// The next number of the sequence.
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        /// A number below `limit`.
        mutating func below(_ limit: Int) -> Int {
            Int(next() % UInt64(limit))
        }

        /// One of `items`, which must not be empty.
        mutating func pick<Item>(_ items: [Item]) -> Item? {
            items.isEmpty ? nil : items[below(items.count)]
        }
    }

    /// Names with a rule of their own in the tree builder, and a few with none.
    private static let names = [
        "div", "span", "p", "li", "ul", "ol", "dd", "dt", "dl", "a", "b", "i", "em", "strong", "font", "u", "s", "nobr", "code",
        "table", "tbody", "thead", "tfoot", "tr", "td", "th", "caption", "colgroup", "col", "form", "select", "option", "optgroup",
        "h1", "h2", "h3", "object", "applet", "marquee", "ruby", "rt", "rp", "button", "input", "textarea", "br", "hr", "img",
        "html", "head", "body", "title", "style", "script", "noscript", "noframes", "plaintext", "frameset", "frame", "x", "y", "name",
        "xmp", "iframe", "noembed", "svg", "math", "template", "section", "pre", "listing", "blockquote", "center", "address", "meta", "link", "base",
    ]

    /// One random piece of markup. `onlyTags` leaves out the pieces that are not
    /// whole tags or text, which keep a document from nesting much.
    private static func piece(_ numbers: inout Numbers, onlyTags: Bool) -> String {
        let name = numbers.pick(names) ?? "x"
        switch numbers.below(onlyTags ? 22 : 40) {
        case 0...8: return "<\(name)>"
        case 9...11: return "<\(name) a=\"\(numbers.below(6))\">"
        case 12...16: return "</\(name)>"
        case 17: return "<\(name)/>"
        case 18: return "x"
        case 19: return " "
        case 20: return "<\(numbers.pick(["b", "i", "font", "a", "em"]) ?? "b") n=\(numbers.below(40))>"
        case 21: return "<\(numbers.pick(["p", "div", "td", "li"]) ?? "p")>"
        case 22: return "<!-- \(name) -->"
        case 23: return "<!--"
        case 24: return "-->"
        case 25: return "<?\(name)>"
        case 26: return "<?\(name) a=\"b\"?>"
        case 27: return "<!\(name)>"
        case 28: return "</?\(name)>"
        case 29: return "<!DOCTYPE \(name)>"
        case 30: return "<![CDATA[\(name)]]>"
        case 31: return "<\(name) a=\"unclosed"
        case 32: return "\""
        case 33: return "&#32;"
        case 34: return "&amp;"
        case 35: return "<"
        case 36: return ">"
        case 37: return "<!--<script>"
        case 38: return "</\(name) a=b>"
        default: return "<\(name) / >"
        }
    }

    /// The document of a round: every fourth one opens as XML, and every second
    /// one is made of whole tags and text.
    static func document(seed: UInt64, round: Int, pieces: Int) -> (text: String, opensAsXML: Bool) {
        var numbers = Numbers(state: seed &* 1_000_003 &+ UInt64(round))
        let opensAsXML = round % 4 == 0
        var text = opensAsXML ? "<?xml version=\"1.0\"?>" : ""
        for _ in 0..<pieces {
            text += piece(&numbers, onlyTags: round % 2 == 1)
        }
        return (text, opensAsXML)
    }

    /// The deepest element of the tree below `root`, found with a stack of its
    /// own, and in the element's own count of parents.
    static func depth<Node>(of root: Node, children: (Node) -> [Node], isElement: (Node) -> Bool) -> Int {
        var work: [(Node, Int)] = [(root, 0)]
        var deepest = 0
        while let (node, depth) = work.popLast() {
            if isElement(node) { deepest = max(deepest, depth) }
            for child in children(node) {
                work.append((child, depth + 1))
            }
        }
        return deepest
    }
}
