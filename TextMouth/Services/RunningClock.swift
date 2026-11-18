import Foundation
import os

/// The time TextMouth has run, in seconds (B18): the system's uptime, less
/// the time iOS held the app suspended, which the in-app engines time their
/// calls and runs by (`InProcessEngine`, FFmpeg's in-app run).
///
/// The system's clocks keep counting while iOS keeps TextMouth suspended and
/// the phone awake (the listener in another app), so a call frozen half way
/// would be taken for a hung one when the listener comes back. iOS tells an
/// app nothing as it suspends it, and the app's lifecycle notices say only
/// that it went to the background, where TextMouth often keeps running (its
/// audio, an import's background task); so the clock looks at its own
/// readings instead:
/// - **Each reading** counts the uptime since the one before, but never more
///   than `longestStep`. A gap longer than that is time the app did not run:
///   its threads were all stopped, as only a suspension stops them.
/// - **A heartbeat** reads the clock every `tick` while something holds it
///   (`hold()`), so that ordinary running time is always counted whole, and
///   only a heartbeat's late tick, a suspension, is not.
///
/// Only differences between readings mean anything: the first reading is 0.
final class RunningClock: Sendable {
    /// The app's clock, which braille's and FFmpeg's engines are timed by.
    static let app = RunningClock()

    /// The system's uptime, every step counted whole, with no heartbeat:
    /// what the Mac times its helpers by, where no app is suspended under its
    /// helper's watchdog.
    static let system = RunningClock(countingWhole: { ProcessInfo.processInfo.systemUptime })

    /// The longest step between two readings that is counted whole, in
    /// seconds: by default 1, four times the heartbeat's 0.25, so a tick late
    /// by less than that, as a busy phone may make it, still counts whole.
    let longestStep: TimeInterval
    /// How often the clock reads itself while held, in seconds; nil for no
    /// heartbeat (a test's clock, read only by what it times).
    let tick: TimeInterval?
    /// The underlying clock, which never runs backwards: the system's uptime,
    /// unless a test scripts its own.
    private let uptime: @Sendable () -> TimeInterval

    /// What the clock has counted so far.
    private struct State: Sendable {
        /// The uptime at the last reading; nil before the first.
        var lastUptime: TimeInterval?
        /// The running time counted up to it.
        var running: TimeInterval = 0
        /// How many holders keep the heartbeat going.
        var holders = 0
        /// Whether a heartbeat is scheduled.
        var ticking = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// The queue the heartbeat reads the clock on.
    private let heartbeat = DispatchQueue(label: "TextMouth running clock", qos: .userInitiated)

    /// A clock counting `uptime` (the system's, by default), at most
    /// `longestStep` seconds between two readings, read every `tick` seconds
    /// while held.
    init(
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        longestStep: TimeInterval = 1,
        tick: TimeInterval? = 0.25
    ) {
        self.uptime = uptime
        self.longestStep = max(0, longestStep)
        self.tick = tick.map { max(0.01, $0) }
    }

    /// A clock that counts every step of `uptime` whole, with no heartbeat:
    /// the system's uptime as it is (`system`), or a test's script.
    convenience init(countingWhole uptime: @escaping @Sendable () -> TimeInterval) {
        self.init(uptime: uptime, longestStep: .infinity, tick: nil)
    }

    /// The running time now: the last reading's, plus the uptime since it, at
    /// most `longestStep`, and never less than the last.
    func now() -> TimeInterval {
        state.withLock { clock in
            let reading = uptime()
            if let last = clock.lastUptime {
                clock.running += min(max(0, reading - last), longestStep)
            }
            clock.lastUptime = max(clock.lastUptime ?? reading, reading)
            return clock.running
        }
    }

    /// Keeps the heartbeat going until a matching `release()`: whatever times
    /// a call or a run holds the clock for as long as it does. The clock is
    /// read at once, so the time just before the hold is counted whole.
    func hold() {
        _ = now()
        let starts = state.withLock { clock -> Bool in
            clock.holders += 1
            guard tick != nil, !clock.ticking else { return false }
            clock.ticking = true
            return true
        }
        if starts { scheduleTick() }
    }

    /// Ends one `hold()`; the heartbeat stops at its next tick once nothing
    /// holds the clock.
    func release() {
        state.withLock { $0.holders = max(0, $0.holders - 1) }
    }

    /// Reads the clock a `tick` from now, and again after that for as long
    /// as it is held. Whether to go on and whether a heartbeat runs are
    /// decided under one lock, so a hold that comes as the last tick ends
    /// starts a new one.
    private func scheduleTick() {
        guard let tick else { return }
        heartbeat.asyncAfter(deadline: .now() + tick) { [self] in
            _ = now()
            let goesOn = state.withLock { clock -> Bool in
                if clock.holders > 0 { return true }
                clock.ticking = false
                return false
            }
            if goesOn { scheduleTick() }
        }
    }
}
