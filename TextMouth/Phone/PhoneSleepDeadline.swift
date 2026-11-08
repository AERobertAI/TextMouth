import Foundation

/// A sleep timer's countdown of minutes on the iPhone, held as the moment it
/// runs out rather than as a count of ticks.
///
/// The Mac's timer takes one second off at each tick of a repeating one-second
/// `Timer`, and a tick that comes late is lost: Apple's documentation for
/// `Timer` says one whose firing "is delayed so far that it passes one or more
/// of the scheduled firing times" is "fired only once for that time period".
/// On a phone, a busy main thread, or a run loop slowed while the screen is
/// locked, would then make the book play on past its time. So on iOS the
/// countdown keeps a deadline, set as it starts and at each resume, and every
/// tick reads what is left from it. The rule that the countdown halts while the
/// book is paused stays, so nothing needs to fire while the app is suspended,
/// which happens only when nothing plays.
///
/// The clock is `ContinuousClock`, which Apple's documentation says "does not
/// stop incrementing while the system is asleep": the time a person sets is the
/// time that passes, whatever the device does meanwhile.
///
/// Plain and shared, so the Mac's test host tests it; only the sleep timer's
/// iOS branch (`SleepTimerService`, under `#if os(iOS)`) uses it.
struct PhoneSleepDeadline: Equatable, Sendable {
    /// The moments, in seconds left, at which the Mac's timer speaks: five
    /// minutes, one minute, thirty seconds, and ten seconds
    /// (`SleepTimerService.announceIfMilestone()`). On the phone they are
    /// logged and never spoken: a sentence over the book, in the dark, heard or
    /// lost by chance, breaks the spec's first principle.
    static let milestones: [Int] = [300, 60, 30, 10]

    /// The moment the countdown reaches zero.
    let endsAt: ContinuousClock.Instant

    /// A deadline `secondsLeft` seconds after `now`; a count below zero is
    /// read as zero, a countdown that has already run out.
    init(secondsLeft: Int, from now: ContinuousClock.Instant) {
        endsAt = now.advanced(by: .seconds(max(0, secondsLeft)))
    }

    /// The whole seconds left at `now`, rounded up, and never below zero.
    ///
    /// Rounded up, so the countdown shows zero only once the deadline has
    /// passed, and so each tick shows what the Mac's would: a tick a moment
    /// after the first second of a 30-minute timer finds 1,798.99 seconds left,
    /// shown as 1,799, "29:59".
    func secondsLeft(at now: ContinuousClock.Instant) -> Int {
        let left = now.duration(to: endsAt)
        guard left > .zero else { return 0 }
        let (seconds, attoseconds) = left.components
        // A positive duration has no negative part, so any fraction of a
        // second left counts as a whole one.
        return Int(seconds) + (attoseconds > 0 ? 1 : 0)
    }

    /// Whether the countdown has run out by `now`.
    func hasRunOut(at now: ContinuousClock.Instant) -> Bool {
        secondsLeft(at: now) == 0
    }

    /// The milestones the countdown passed in going from `previous` seconds
    /// left to `current`: each one it reached or went below, and had not
    /// reached before, from the earliest to the latest.
    ///
    /// The Mac's timer matches each second exactly, since it never skips one;
    /// a deadline's late tick can jump past a milestone, so it is crossed, not
    /// matched: from 302 to 299 still passes 300. A timer started at exactly a
    /// milestone has not passed it, as on the Mac, whose five-minute timer
    /// never says "5 minutes remaining".
    static func milestonesPassed(from previous: Int, to current: Int) -> [Int] {
        milestones.filter { current <= $0 && $0 < previous }
    }

    /// What one tick of the countdown finds.
    struct Tick: Equatable, Sendable {
        /// The whole seconds left, as the timer shows them.
        let secondsLeft: Int
        /// The milestones passed since the tick before, earliest first.
        let milestonesPassed: [Int]
        /// The seconds this tick jumped over beyond its own one: zero for a
        /// tick on time. More is the evidence of late ticks that the first run
        /// on a phone should log.
        let skippedSeconds: Int

        /// Whether the countdown has run out, so the timer expires now.
        var hasRunOut: Bool { secondsLeft == 0 }

        /// Whether the tick is worth a line in the timer's progress trace: a
        /// minute's boundary, the last ten seconds, or a jump, as the Mac
        /// writes a line at minute boundaries and in the last ten seconds.
        var isWorthTracing: Bool {
            secondsLeft % 60 == 0 || secondsLeft <= 10 || skippedSeconds > 0
        }
    }

    /// What a tick at `now` finds, the timer having shown `previousSecondsLeft`
    /// before it. A tick never shows more time than the one before, so a clock
    /// read a moment early never makes the countdown go back up.
    func tick(at now: ContinuousClock.Instant, after previousSecondsLeft: Int) -> Tick {
        let current = min(secondsLeft(at: now), max(0, previousSecondsLeft))
        return Tick(
            secondsLeft: current,
            milestonesPassed: Self.milestonesPassed(from: previousSecondsLeft, to: current),
            skippedSeconds: max(0, previousSecondsLeft - current - 1)
        )
    }
}
