import Foundation

/// Which row of a list VoiceOver's focus should go to, for every list of the
/// iPhone app (the engineering review's F12).
///
/// A request for focus on a row a list has not made yet does nothing, and says
/// so to no one. So the iOS helper (`PhoneListFocus+iOS`) scrolls the row into
/// being, waits `settleDelay`, then sets the focus to nil and to the row, since
/// setting the same value twice does nothing either. What row that is, this
/// plain type decides.
enum PhoneListFocus {
    /// How long the iOS helper waits after scrolling, in seconds, for the list
    /// to make the row.
    static let settleDelay: TimeInterval = 0.35

    /// The row to focus: `wanted` while the list holds it, else `fallback`
    /// while the list holds that, else none.
    static func row<ID: Hashable>(_ wanted: ID, in rows: [ID], fallback: ID?) -> ID? {
        if rows.contains(wanted) { return wanted }
        if let fallback, rows.contains(fallback) { return fallback }
        return nil
    }

    /// The row to fall back to for `gone`, a row no longer in the list: the
    /// first of the rows after it in the old list that the new one still
    /// holds, else the nearest before it, else `otherwise`, such as the
    /// Continue row.
    static func fallback<ID: Hashable>(forGone gone: ID, oldRows: [ID], newRows: [ID], otherwise: ID?) -> ID? {
        let remaining = Set(newRows)
        guard let index = oldRows.firstIndex(of: gone) else { return otherwise }
        if let after = oldRows[oldRows.index(after: index)...].first(where: remaining.contains) {
            return after
        }
        if let before = oldRows[..<index].last(where: remaining.contains) {
            return before
        }
        return otherwise
    }
}
