import Foundation

/// The words TextMouth says, aloud and on screen, while it finishes work
/// before it quits (`QuitFinisher`). One place, so the announcement and the
/// panel say the same thing, as often as the person asks to quit again.
enum QuitHoldWording {
    /// The panel's title.
    static let title = "Quitting TextMouth"

    /// The words for `phrases`, what each piece of work is doing
    /// (`QuitHold.Work.finishing`): what is under way, and that TextMouth
    /// quits afterwards.
    static func message(finishing phrases: [String]) -> String {
        "TextMouth is finishing up before it quits: \(list(phrases)). It will quit as soon as that is done."
    }

    /// `items` in a sentence: "a", "a and b", or "a, b, and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

/// Finishes the work a quit must not cut off, for a quit the person asked
/// for, and then asks to quit again.
///
/// The delegate cancels the quit while this works (`finish(_:)` returns
/// true), instead of leaving the quit pending. A pending quit does not ask
/// the delegate again when the person presses Command-Q a second time, or
/// chooses Quit in the Dock: AppKit quits at once, cutting the work off. A
/// cancelled quit does ask. The delegate then asks `answerRepeatedRequest()`,
/// which says again what is finishing and cancels that request too, so a
/// second request never cuts anything off and never goes unanswered.
///
/// When the work has ended, or has had its longest wait, `askAgain` asks to
/// quit once more (`QuitRequest.ask()`), and `takeFinished()` tells that
/// request, once, that the work is done, so a wait is not begun again for
/// work that gave up waiting.
@MainActor
final class QuitFinisher {
    /// Says its message, aloud and on screen.
    private let tell: @MainActor (String) -> Void
    /// Called when the work has ended, to take the notice down.
    private let finished: @MainActor () -> Void
    /// Asks to quit again.
    private let askAgain: @MainActor () -> Void

    /// The wait for the work, while it runs.
    private var finishing: Task<Void, Never>?
    /// What is said while the work runs, to say again.
    private var message: String?
    /// Whether the work ended since the delegate last asked, so the quit
    /// asked again goes ahead.
    private var hasFinished = false

    /// A finisher that `tell`s the person what it is finishing, calls
    /// `finished` when the work is done, and `askAgain` to quit again.
    init(
        tell: @escaping @MainActor (String) -> Void,
        finished: @escaping @MainActor () -> Void,
        askAgain: @escaping @MainActor () -> Void = { QuitRequest.ask() }
    ) {
        self.tell = tell
        self.finished = finished
        self.askAgain = askAgain
    }

    /// Whether the work is being finished now.
    var isFinishing: Bool {
        finishing != nil
    }

    /// Starts finishing each of `works` that runs now, one after another,
    /// each for at most its longest wait, saying what it finishes, and
    /// returns whether it did, for the delegate to cancel this quit. When it
    /// returns false, nothing runs and the quit goes ahead. Work already
    /// being finished is not started again.
    func finish(_ works: [QuitHold.Work]) -> Bool {
        guard !isFinishing else { return true }
        let running = works.filter { $0.isRunning() }
        guard !running.isEmpty else { return false }
        let words = QuitHoldWording.message(finishing: running.map(\.finishing))
        message = words
        tell(words)
        finishing = Task { [weak self] in
            for work in running {
                await QuitHold.end(work)
            }
            self?.didFinish()
        }
        return true
    }

    /// Answers a request to quit that comes while the work is being
    /// finished, such as a second Command-Q: says again what is finishing and
    /// returns true, for the delegate to cancel that request. Returns false
    /// when no work is being finished.
    func answerRepeatedRequest() -> Bool {
        guard isFinishing, let message else { return false }
        tell(message)
        return true
    }

    /// Whether the work has ended since the last call, for the request to
    /// quit that follows its end. The answer is given once.
    func takeFinished() -> Bool {
        defer { hasFinished = false }
        return hasFinished
    }

    /// The work has ended or had its longest wait: the notice comes down and
    /// TextMouth asks to quit again.
    private func didFinish() {
        finishing = nil
        message = nil
        hasFinished = true
        finished()
        askAgain()
    }
}
