import Foundation

/// Which navigation units a book offers on the iPhone, which is in force, and
/// how adjusting Navigation unit steps through them (the spec, under
/// "Navigation unit").
///
/// The phone keeps one unit per book for both directions, as the Mac's "One
/// Unit for Both Directions" mode does, and a default for each kind of book
/// until a book has its own. The Mac's list and order are kept, with two
/// differences: Sentence and Paragraph aren't offered for an audiobook, which
/// has no text to stop at (its chapters are spaces, so on the Mac they do
/// nothing, in silence), and Page isn't offered for a book of fewer than two
/// pages, as on the Mac. Which unit is in force, from what's offered, is
/// `PhoneDefaults.navigationUnit(ownRawValue:isAudio:offered:in:)`: a unit a
/// book doesn't offer falls to its kind's default, never to one that would do
/// nothing.
enum PhoneNavigationUnits {
    /// The units a book offers, in the Mac's order (`SkipUnit.allCases`).
    ///
    /// - Parameters:
    ///   - isAudioBook: Whether the book is an audiobook, transcribed or not
    ///     (the spec treats a transcribed one the same, for now).
    ///   - hasSeveralPages: Whether the book has more than one page, the
    ///     Mac's `hasSeveralPages`: a book of one page has no other to go to.
    static func offered(isAudioBook: Bool, hasSeveralPages: Bool) -> [SkipUnit] {
        SkipUnit.allCases.filter { unit in
            switch unit {
            case .sentence, .paragraph: return !isAudioBook
            case .page: return hasSeveralPages
            default: return true
            }
        }
    }

    /// The unit after `unit` among `offered` when adjusting up, or before it
    /// when adjusting down, wrapping around at either end, as the Mac's cycle
    /// does. A unit not among `offered` steps from where it would sit in the
    /// Mac's order, so a step always lands on an offered unit.
    static func unit(after unit: SkipUnit, up: Bool, in offered: [SkipUnit]) -> SkipUnit {
        guard !offered.isEmpty else { return unit }
        if let index = offered.firstIndex(of: unit) {
            let step = up ? 1 : -1
            return offered[(index + step + offered.count) % offered.count]
        }
        // Not offered: the offered unit that follows it (or precedes it) in
        // the Mac's order, wrapping around.
        let order = SkipUnit.allCases
        let position = order.firstIndex(of: unit) ?? 0
        let candidates = up
            ? Array(order[(position + 1)...]) + Array(order[...position])
            : Array(order[..<position].reversed()) + Array(order[position...].reversed())
        return candidates.first(where: offered.contains) ?? offered[0]
    }

    /// The unit's name in lower case, for hints and the "nothing that way"
    /// words: "sentence", "10 seconds", "subheading".
    static func lowercasedName(of unit: SkipUnit) -> String {
        unit.rawValue.lowercased()
    }
}
