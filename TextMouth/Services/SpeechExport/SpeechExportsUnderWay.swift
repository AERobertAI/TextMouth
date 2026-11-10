import Foundation

/// The speech exports under way (FMT43), which a quit stops cleanly before
/// TextMouth quits, as it lets feed downloads and a book's re-read reach a
/// safe end first (`QuitHold`).
///
/// Speaking a book can take an hour. A quit that ended one where it stood
/// would cut a chapter's file off midway and leave its scratch folder behind;
/// stopped as Stop stops it, the export keeps every chapter it finished,
/// removes its scratch folder, lets the Mac sleep again, and writes its line
/// in the debug log. Each Export dialog's speech export says when it begins
/// and ends (`begin(_:)`, `ended(_:)`), and a quit waits for them all.
@MainActor
final class SpeechExportsUnderWay {
    /// The app's: every Export dialog's speech export says when it begins and
    /// ends here, unless a test gives the dialog its own.
    static let shared = SpeechExportsUnderWay()

    /// The longest a quit waits for the exports to stop. Stop is noticed
    /// within a quarter of a second while a chapter is spoken, and within a
    /// tenth while the file is encoded, so a few seconds is ample; past them
    /// TextMouth quits anyway, as it does for any held work.
    static let longestQuitWait: Duration = .seconds(5)

    /// Each export under way's Stop, by an ID of its own.
    private var stops: [UUID: BookExportCancellation] = [:]
    /// Those waiting for every export under way to have ended.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A record of speech exports of its own: the app's is `shared`.
    init() {}

    /// Whether a speech export is under way.
    var isRunning: Bool {
        !stops.isEmpty
    }

    /// Notes that a speech export stopped by `cancellation` has begun, until
    /// `ended(_:)` is told the ID this returns.
    func begin(_ cancellation: BookExportCancellation) -> UUID {
        let id = UUID()
        stops[id] = cancellation
        return id
    }

    /// Notes that the speech export `begin(_:)` gave `id` has ended; once
    /// none is under way, whoever waits for them goes on.
    func ended(_ id: UUID) {
        stops[id] = nil
        guard stops.isEmpty else { return }
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Stops every speech export under way, as Stop stops it, which keeps the
    /// chapters it finished, and returns once each has ended.
    func stopAll() async {
        guard isRunning else { return }
        for stop in stops.values {
            stop.cancel()
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The work a quit waits for while a speech export is under way: every
    /// export stopped cleanly, for at most `longestWait`.
    func quitWork(longestWait: Duration = SpeechExportsUnderWay.longestQuitWait) -> QuitHold.Work {
        QuitHold.Work(
            isRunning: { self.isRunning },
            end: { await self.stopAll() },
            longestWait: longestWait,
            finishing: "stopping a speech export with the chapters it finished kept"
        )
    }
}
