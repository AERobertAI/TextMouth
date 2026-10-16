import Foundation

/// What happens when a book ends, and how listening goes on from it, once
/// every setting that has a say is weighed (FR19). This is the one place the
/// order of precedence is written in code.
///
/// Strongest first:
/// 1. The reading list, when the book was opened from it. The list's own
///    "When a book ends" rules, and the reader asks it before it asks this
///    type, so it is not an input here.
/// 2. The book's own end behavior (`Book.localEndOfBookBehavior`, set in the
///    reader's settings sheet), which always goes to the book below. A raw
///    value that names no `EndOfBookBehavior` is ignored.
/// 3. The options of the feed or plain folder the book is in
///    (`ListeningOptions.continuation`), unless it is nil, "Use the global
///    setting": play the book below (Continue to Next Book going down), play
///    the book above (Continue to Next Book going up), or stop.
/// 4. The global setting (`SettingsViewModel.endOfBookBehavior`), which
///    always goes to the book below.
///
/// Whichever layer wins, "Skip finished" and "Download the next episode"
/// are the feed's or folder's own (true when it has no options): they apply
/// whenever listening goes on from one of its items to another, whoever sent
/// it there.
struct EndOfBookRule: Equatable, Sendable {
    /// What the book does at its end.
    var behavior: EndOfBookBehavior
    /// Which way listening goes on when `behavior` is Continue to Next Book:
    /// down to the item below, or up to the item above.
    var direction: ReadingList.Direction
    /// Whether finished items are passed over when listening goes on.
    var skipsFinished: Bool
    /// Whether the item that follows is downloaded shortly before it is
    /// needed (a feed's items only).
    var predownloadsNext: Bool

    /// The rule in force for a book.
    ///
    /// - Parameters:
    ///   - localRawValue: The book's own end behavior as saved, or nil.
    ///   - options: The options of the book's feed or plain folder, or nil
    ///     when it has none of its own.
    ///   - global: The global "When book ends" setting.
    static func resolve(
        localRawValue: String?,
        options: ListeningOptions?,
        global: EndOfBookBehavior
    ) -> EndOfBookRule {
        // "Skip finished" and pre-download come from the options whatever
        // layer decides the behavior; no options means their defaults.
        let skipsFinished = options?.skipsFinished ?? ListeningOptions.standard.skipsFinished
        let predownloadsNext = options?.predownloadsNext ?? ListeningOptions.standard.predownloadsNext

        // A small builder for the layers below, which differ only in the
        // behavior and the direction.
        func rule(_ behavior: EndOfBookBehavior, _ direction: ReadingList.Direction) -> EndOfBookRule {
            EndOfBookRule(
                behavior: behavior,
                direction: direction,
                skipsFinished: skipsFinished,
                predownloadsNext: predownloadsNext
            )
        }

        // 2. The book's own choice wins, and goes down.
        if let localRawValue, let local = EndOfBookBehavior(rawValue: localRawValue) {
            return rule(local, .down)
        }
        // 3. The feed's or folder's choice, when it has made one.
        switch options?.continuation {
        case .playBookBelow: return rule(.continueNext, .down)
        case .playBookAbove: return rule(.continueNext, .up)
        case .stop: return rule(.stop, .down)
        case nil: break
        }
        // 4. The global setting.
        return rule(global, .down)
    }
}
