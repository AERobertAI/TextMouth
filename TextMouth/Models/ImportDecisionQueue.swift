import Foundation

/// The questions imports are waiting to ask, asked one at a time in the
/// order they arose (TODO I01).
///
/// Imports run one after another off the main thread and go on running
/// while a question waits, so several questions can arise before the user
/// answers the first. Each is queued behind the others, never put in place
/// of one: the first waiting is the one asked, and settling it asks the
/// next. A question that an answer raises about the same file, such as
/// whether to delete the original of a duplicate just kept, is asked right
/// after it, before the rest, so one file's questions stay together.
///
/// The queue also counts the questions settled since it was last empty, so
/// the sheet can say where the current one stands, as in "2 of 3".
struct ImportDecisionQueue {
    /// The questions waiting, the one being asked first.
    private(set) var waiting: [ImportDecision] = []
    /// How many questions were settled since the queue was last empty.
    private(set) var settledCount = 0
    /// The question whose answer is being carried out off the main actor
    /// (Replace Existing of a long braille book), nil while none is. No other
    /// answer acts meanwhile, so one question is never answered twice, nor
    /// settled by an answer that began for another.
    private(set) var answering: ImportDecision.ID?

    /// The question being asked, or nil when none is waiting.
    var current: ImportDecision? { waiting.first }

    /// Whether no question is waiting.
    var isEmpty: Bool { waiting.isEmpty }

    /// The current question's place among the questions asked since the
    /// queue was last empty, counting from one.
    var position: Int { settledCount + 1 }

    /// How many questions have been asked since the queue was last empty:
    /// those settled, and those waiting, the current one included.
    var total: Int { settledCount + waiting.count }

    /// Queues `decision` behind every question waiting.
    mutating func enqueue(_ decision: ImportDecision) {
        waiting.append(decision)
    }

    /// Marks the question `id` as being answered off the main actor.
    ///
    /// - Returns: Whether it was marked; false when an answer is already
    ///   being carried out, which stands.
    @discardableResult
    mutating func beginAnswering(_ id: ImportDecision.ID) -> Bool {
        guard answering == nil else { return false }
        answering = id
        return true
    }

    /// Ends the answer being carried out off the main actor, whatever came of it.
    mutating func endAnswering() {
        answering = nil
    }

    /// Settles the question being asked and, when its answer raised
    /// `followUp`, a question about the same file, asks that one next.
    ///
    /// - Returns: The question settled, or nil when none was waiting.
    @discardableResult
    mutating func settleCurrent(followedBy followUp: ImportDecision? = nil) -> ImportDecision? {
        guard !waiting.isEmpty else { return nil }
        let settled = waiting.removeFirst()
        settledCount += 1
        if let followUp {
            waiting.insert(followUp, at: 0)
        }
        restartCountIfEmpty()
        return settled
    }

    /// Withdraws, unasked, every waiting question `isWithdrawn` picks, the
    /// one being asked included, and keeps the rest in their order.
    /// Withdrawn questions do not count as settled.
    ///
    /// - Returns: The questions withdrawn, in their order.
    mutating func withdrawAll(where isWithdrawn: (ImportDecision) -> Bool) -> [ImportDecision] {
        var kept: [ImportDecision] = []
        var withdrawn: [ImportDecision] = []
        // One pass, so each question is judged exactly once.
        for decision in waiting {
            if isWithdrawn(decision) {
                withdrawn.append(decision)
            } else {
                kept.append(decision)
            }
        }
        waiting = kept
        restartCountIfEmpty()
        return withdrawn
    }

    /// Passes every book the waiting questions hold through `transform`,
    /// keeping the questions, their order, and the count as they are. A
    /// data-directory move gives the books their file paths in the new data
    /// directory this way (TODO S04).
    mutating func mapBooks(_ transform: (Book) -> Book) {
        waiting = waiting.map { $0.mappingBooks(transform) }
    }

    /// Starts counting afresh once no question is waiting, so the next
    /// question to arise is "1 of" the questions that follow it.
    private mutating func restartCountIfEmpty() {
        if waiting.isEmpty {
            settledCount = 0
        }
    }

    // MARK: - Which Window Asks

    /// The Library window that asks a question whose import started in
    /// `origin`: that window while it is open, or else the first of
    /// `openWindows`, the open Library windows in the order they
    /// registered. Exactly one window asks each question, and a question
    /// whose window has closed is still asked. Nil while no Library window
    /// is open: the question waits for one.
    static func askingWindow(for origin: ImportOrigin?, among openWindows: [ImportOrigin]) -> ImportOrigin? {
        if let origin, openWindows.contains(origin) {
            return origin
        }
        return openWindows.first
    }
}
