import Foundation
private import TextMouthBrailleProtocol

// MARK: - Emphasis

/// The emphasis of one character in TextMouth's own vocabulary, the same for
/// every braille table: what travels with each character of a paragraph
/// through the braille helper (protocol 2, whose single definition is
/// `TextMouthBraille/include/TextMouthBrailleProtocol.h`, which this type
/// reads its values from).
///
/// The user, asked whether exported braille should mark italics and bold
/// (October 21, 2026): "it should try keeping all text formatting
/// extractable from the braille converted to the intermediate format". So
/// reading braille keeps the emphasis liblouis reports, and writing braille
/// passes the book's emphasis to liblouis, which writes the table's
/// indicators: both only for the tables whose indicators liblouis reads
/// back exactly (UEB's), checked by the helper on each run.
struct BrailleEmphasis: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    /// A set of flags; bits the protocol does not have are dropped.
    init(rawValue: UInt8) {
        self.rawValue = rawValue & UInt8(TMB_EMPHASIS_ALL)
    }

    /// Italic: liblouis's "italic" class.
    static let italic = BrailleEmphasis(rawValue: UInt8(TMB_EMPHASIS_ITALIC))
    /// Bold: liblouis's "bold" class.
    static let bold = BrailleEmphasis(rawValue: UInt8(TMB_EMPHASIS_BOLD))
    /// Underline: liblouis's "underline" class.
    static let underline = BrailleEmphasis(rawValue: UInt8(TMB_EMPHASIS_UNDERLINE))
    /// Script: liblouis's "script" class, which UEB has.
    static let script = BrailleEmphasis(rawValue: UInt8(TMB_EMPHASIS_SCRIPT))
    /// A transcriber-defined typeface: liblouis's "trans1" to "trans5", one
    /// flag for all five, which UEB has for typefaces of the print it has no
    /// indicator of its own for.
    static let transcriber = BrailleEmphasis(rawValue: UInt8(TMB_EMPHASIS_TRANSCRIBER))

    // MARK: Codes

    /// The protocol's code for these flags: one printable ASCII byte, "@"
    /// for none, "A" for italic, "B" for bold, "C" for both, up to "_".
    var code: UInt8 {
        UInt8(TMB_EMPHASIS_CODE_PLAIN) + rawValue
    }

    /// The flags `code` stands for, or nil for a byte that is no code.
    init?(code: UInt8) {
        let plain = UInt8(TMB_EMPHASIS_CODE_PLAIN)
        guard code >= plain, code - plain <= UInt8(TMB_EMPHASIS_ALL) else { return nil }
        self.init(rawValue: code - plain)
    }

    /// The first line of every file the helper reads and writes: the
    /// protocol and its version.
    static let protocolHeader: String = TMB_PROTOCOL_HEADER

    // MARK: Markdown

    /// How content.md, which TextMouth's reader reads, carries these flags:
    /// italic as emphasis (`*…*`), bold as strong emphasis (`**…**`), both as
    /// both (`***…***`). Markdown has no underline, script, or
    /// transcriber-defined typeface, and none of TextMouth's other readers
    /// carries underline into content.md today: DOCX keeps bold, italic, and
    /// strikethrough (`DOCXParser+Converter`), and HTML, which RTF and Word
    /// 97-2003 reach through textutil, keeps `em`, `i`, `strong`, and `b`
    /// (`HTMLToMarkdownConverter`); both drop underline. So these three are
    /// carried as emphasis, the nearest thing the reader holds, rather than
    /// lost (the user, October 21, 2026: "keeping all text formatting
    /// extractable from the braille").
    var markdownStyle: MarkdownEmphasis.Style {
        var style: MarkdownEmphasis.Style = []
        if !isDisjoint(with: [.italic, .underline, .script, .transcriber]) { style.insert(.emphasis) }
        if contains(.bold) { style.insert(.strong) }
        return style
    }
}

// MARK: - Text With Its Emphasis

/// Text with the emphasis of each of its Unicode scalars: a paragraph as it
/// travels through the braille helper (protocol 2). The text is print, or
/// braille cells, which hold their emphasis in their indicators and so
/// travel with none.
///
/// Most paragraphs have no emphasis at all, so a text with none keeps no
/// array for it: `emphasis` is empty, never a list of plain flags, which is
/// also what makes two equal texts compare equal.
struct EmphasizedText: Equatable, Sendable {
    /// The text.
    private(set) var text: String
    /// The emphasis of each Unicode scalar of `text`, in order; empty when
    /// no scalar has any.
    private(set) var emphasis: [BrailleEmphasis]
    /// How many Unicode scalars `text` has, kept so that appending never
    /// counts them again.
    private var scalarCount: Int

    /// `text` with no emphasis.
    init(_ text: String = "") {
        self.text = text
        emphasis = []
        scalarCount = text.unicodeScalars.count
    }

    /// `text` with `emphasis`, one for each of its Unicode scalars in order
    /// (or none at all); nil when the counts differ, which no caller can
    /// make sense of. Emphasis that is all plain is kept as none.
    init?(_ text: String, emphasis: [BrailleEmphasis]) {
        let count = text.unicodeScalars.count
        guard emphasis.isEmpty || emphasis.count == count else { return nil }
        self.text = text
        self.emphasis = emphasis.contains { !$0.isEmpty } ? emphasis : []
        scalarCount = count
    }

    /// Whether any scalar has emphasis.
    var hasEmphasis: Bool {
        !emphasis.isEmpty
    }

    /// The emphasis of the first scalar: none for an empty text, or one
    /// with no emphasis.
    var firstEmphasis: BrailleEmphasis {
        emphasis.first ?? []
    }

    /// The emphasis of the last scalar: none for an empty text, or one with
    /// no emphasis.
    var lastEmphasis: BrailleEmphasis {
        emphasis.last ?? []
    }

    /// Adds `scalar`, with `flags`.
    mutating func append(_ scalar: Unicode.Scalar, _ flags: BrailleEmphasis) {
        if keepsEmphasis(adding: !flags.isEmpty) { emphasis.append(flags) }
        text.unicodeScalars.append(scalar)
        scalarCount += 1
    }

    /// Adds every scalar of `string`, each with `flags`.
    mutating func append(contentsOf string: String, _ flags: BrailleEmphasis) {
        let count = string.unicodeScalars.count
        guard count > 0 else { return }
        if keepsEmphasis(adding: !flags.isEmpty) { emphasis.append(contentsOf: repeatElement(flags, count: count)) }
        text += string
        scalarCount += count
    }

    /// Adds `other`, with its emphasis.
    mutating func append(_ other: EmphasizedText) {
        guard other.scalarCount > 0 else { return }
        if keepsEmphasis(adding: other.hasEmphasis) {
            if other.hasEmphasis {
                emphasis.append(contentsOf: other.emphasis)
            } else {
                emphasis.append(contentsOf: repeatElement([], count: other.scalarCount))
            }
        }
        text += other.text
        scalarCount += other.scalarCount
    }

    /// The text with the white space and line breaks at both of its ends
    /// removed, and their emphasis with them, as `trimmingCharacters(in:
    /// .whitespacesAndNewlines)` trims a string: a scalar at a time.
    func trimmingWhitespace() -> EmphasizedText {
        let scalars = Array(text.unicodeScalars)
        var lower = 0
        var upper = scalars.count
        while lower < upper, CharacterSet.whitespacesAndNewlines.contains(scalars[lower]) { lower += 1 }
        while upper > lower, CharacterSet.whitespacesAndNewlines.contains(scalars[upper - 1]) { upper -= 1 }
        guard lower > 0 || upper < scalars.count else { return self }
        let kept = String(String.UnicodeScalarView(scalars[lower..<upper]))
        let flags = hasEmphasis ? Array(emphasis[lower..<upper]) : []
        return EmphasizedText(kept, emphasis: flags) ?? EmphasizedText(kept)
    }

    /// Whether scalars about to be added need entries in `emphasis`, called
    /// before they are counted: yes when the text has emphasis already, or
    /// when they bring the first, in which case every scalar so far is given
    /// its plain entry first, so that `emphasis` stays one entry per scalar.
    /// The answer is returned rather than read from `hasEmphasis`
    /// afterwards: for an empty text those entries are none at all, and the
    /// array would still be empty.
    private mutating func keepsEmphasis(adding incoming: Bool) -> Bool {
        guard !hasEmphasis else { return true }
        guard incoming else { return false }
        emphasis = Array(repeating: [], count: scalarCount)
        return true
    }
}
