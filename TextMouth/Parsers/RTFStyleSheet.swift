import Foundation

// MARK: - The Style Sheet

/// The paragraph styles of a Rich Text Format document's `\stylesheet`
/// (FMT47), and which of them are headings.
///
/// A paragraph style says it is a heading in the two ways Word does: its
/// name is "heading 1" to "heading 9" (in any capitals), and its
/// `\outlinelevelN` is 0 to 8 (levels 1 to 9). An outline level wins over the
/// name, as the Word reader's does (`DOCXStylesParser`), and 9 means body
/// text. Levels deeper than 6 are level 6. "Title" is level 1 and "Subtitle"
/// level 2, as there. A style that says nothing takes what the style it is
/// `\sbasedon` says.
struct RTFStyleSheet {
    /// The most styles kept: a real document has hundreds, so more is a
    /// hostile file, whose styles after these are ignored.
    static let mostStyles = 100_000

    /// What a style says about being a heading by itself.
    fileprivate enum Own: Equatable {
        /// A heading at this level, 1 through 6.
        case heading(Int)
        /// Body text, whatever the style it is based on is.
        case body
    }

    /// One style as the style sheet declares it.
    private struct Style {
        /// The style's name, as written before the semicolon.
        var name = ""
        /// The `\outlinelevelN` the style declares, if any.
        var outlineLevel: Int?
        /// The number of the style this one is `\sbasedon`, if any.
        var basedOn: Int?
        /// Whether the style's paragraphs begin a page (`\pagebb`).
        var pageBreakBefore = false

        /// What the style says by itself, or nil when it says nothing.
        var own: Own? {
            if let outlineLevel { return RTFStyleSheet.own(forOutlineLevel: outlineLevel) }
            let lower = name.lowercased()
            if lower.hasPrefix("heading "),
               let number = Int(lower.dropFirst("heading ".count).trimmingCharacters(in: .whitespaces)),
               number >= 1 {
                return .heading(min(number, 6))
            }
            if lower == "title" { return .heading(1) }
            if lower == "subtitle" { return .heading(2) }
            return nil
        }
    }

    /// The styles, by style number.
    private var styles: [Int: Style] = [:]

    /// The answer `headingLevel(ofStyle:)` already worked out for a style,
    /// where nil inside means "not a heading".
    private var resolved: [Int: Int?] = [:]

    /// What an outline level of a paragraph or a style says: levels 0 to 8
    /// are headings 1 to 6 (the deepest three share 6), and every other
    /// number is body text.
    fileprivate static func own(forOutlineLevel level: Int) -> Own {
        (0...8).contains(level) ? .heading(min(level + 1, 6)) : .body
    }

    /// The heading level (1 to 6) that an outline level of a paragraph gives,
    /// or nil for body text.
    static func headingLevel(forOutlineLevel level: Int) -> Int? {
        if case .heading(let level) = own(forOutlineLevel: level) { return level }
        return nil
    }

    // MARK: Building

    /// Records a style whose definition is complete.
    mutating func add(number: Int, name: String, outlineLevel: Int?, basedOn: Int?, pageBreakBefore: Bool) {
        guard styles.count < Self.mostStyles || styles[number] != nil else { return }
        styles[number] = Style(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            outlineLevel: outlineLevel,
            basedOn: basedOn,
            pageBreakBefore: pageBreakBefore
        )
        // A later definition can change an answer already worked out.
        resolved.removeAll(keepingCapacity: true)
    }

    // MARK: Asking

    /// The heading level (1 to 6) the paragraph style `number` gives, or nil
    /// when it is not a heading style (or is not in the style sheet). The
    /// `\sbasedon` chain is followed in a loop to the first style that says
    /// anything; a chain that loops back on itself, or runs to a style the
    /// sheet does not define, gives nil.
    mutating func headingLevel(ofStyle number: Int) -> Int? {
        if let known = resolved[number] { return known }
        var visited: Set<Int> = []
        var current: Int? = number
        var answer: Int?
        while let key = current, let style = styles[key], visited.insert(key).inserted {
            if let own = style.own {
                if case .heading(let level) = own { answer = level }
                break
            }
            current = style.basedOn
        }
        resolved[number] = .some(answer)
        return answer
    }

    /// Whether paragraphs of style `number` begin a page (`\pagebb` in the
    /// style or in the styles it is based on), following the chain as
    /// `headingLevel(ofStyle:)` does.
    func beginsPage(ofStyle number: Int) -> Bool {
        var visited: Set<Int> = []
        var current: Int? = number
        while let key = current, let style = styles[key], visited.insert(key).inserted {
            if style.pageBreakBefore { return true }
            current = style.basedOn
        }
        return false
    }
}
