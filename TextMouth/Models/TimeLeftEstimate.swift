import Foundation

// MARK: - What the Finished Items Took (FR10)

/// What the finished items of one run of work took, the books of a ZIP
/// batch or the downloads of a run of feed downloads, which the time the run
/// has left is estimated from (`TimeLeftEstimate`, FR10): each item's
/// seconds, and its bytes where its size tells its time.
///
/// The caller adds only the items whose time says something of the next: a
/// ZIP batch's books imported or failed, not those skipped as duplicates,
/// which take next to no time; a run's downloads finished, not those that
/// failed, which can fail at once or after a long wait.
struct WorkTiming: Equatable, Sendable {
    /// The items timed.
    private(set) var items = 0
    /// The seconds they took in all.
    private(set) var seconds: TimeInterval = 0
    /// The items timed by their size: an episode's file counted as it came,
    /// a text book's file.
    private(set) var sizedItems = 0
    /// The bytes of those items.
    private(set) var sizedBytes: Int64 = 0
    /// The seconds those items took in all.
    private(set) var sizedSeconds: TimeInterval = 0

    /// The items timed without a size: an article, whose page comes with no
    /// count of its bytes, or an audiobook's file, whose size says little of
    /// its import's time.
    var unsizedItems: Int {
        items - sizedItems
    }

    /// The seconds the items timed without a size took in all.
    var unsizedSeconds: TimeInterval {
        max(0, seconds - sizedSeconds)
    }

    /// Notes an item that took `seconds`, `bytes` long when its size tells
    /// its time, or 0 when it has none that does.
    mutating func add(seconds: TimeInterval, bytes: Int64) {
        // A clock moved back, or a time that is no number, counts as none.
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        items += 1
        self.seconds += seconds
        if bytes > 0 {
            sizedItems += 1
            sizedBytes += bytes
            sizedSeconds += seconds
        }
    }
}

// MARK: - The Time Left (FR10)

/// How long the items of a run not yet finished should take, estimated from
/// those finished so far, by size where sizes tell the time (FR10): a ZIP
/// batch's text books, and a feed's episodes, which can be 5 MB or 120 MB.
/// The import overlay and the feed downloads section both estimate this
/// way, and say the time left as `ImportProgressWording.timeLeft(_:)` words
/// it.
enum TimeLeftEstimate {
    /// One item still to come: the bytes it has yet to take, when they are
    /// known and tell its time (the rest of the download under way, a
    /// waiting download's size as its feed gives it, a text book's file),
    /// and, for the item under way, the seconds it has run so far.
    struct Remaining: Equatable, Sendable {
        /// The bytes still to come; nil when unknown or when they say little
        /// of the item's time, as for an article or an audiobook's file.
        var bytes: Int64?
        /// The seconds the item has run; 0 for one waiting to start.
        var elapsed: TimeInterval = 0
    }

    /// The seconds the items `remaining` should take after the items
    /// `timing` counts, or nil before any item was timed, and with none
    /// left.
    ///
    /// An item of known size takes its bytes at the rate the items timed by
    /// size took theirs. Any other item takes the average time of the items
    /// timed without a size, as an article takes a second however long the
    /// episodes beside it took, or, before any of those was timed, the
    /// average of every item timed, less the time it has run already; so
    /// does an item of known size before any item was timed by size. So a
    /// run of a podcast's large episodes and a blog's articles, or a batch
    /// of text books and audiobooks, counts each kind at its own pace.
    static func secondsLeft(after timing: WorkTiming, for remaining: [Remaining]) -> TimeInterval? {
        guard timing.items > 0, !remaining.isEmpty, timing.seconds.isFinite else { return nil }
        let bytesPerSecond: Double? = timing.sizedBytes > 0 && timing.sizedSeconds > 0
            ? Double(timing.sizedBytes) / timing.sizedSeconds
            : nil
        let averageSeconds = timing.unsizedItems > 0
            ? timing.unsizedSeconds / Double(timing.unsizedItems)
            : timing.seconds / Double(timing.items)
        return remaining.reduce(0) { total, item in
            if let bytes = item.bytes, let bytesPerSecond {
                return total + Double(max(0, bytes)) / bytesPerSecond
            }
            return total + max(0, averageSeconds - max(0, item.elapsed))
        }
    }

    /// `seconds` as the time left is said: 0 under a minute, which is said
    /// as "less than a minute"; otherwise rounded to the nearest whole
    /// minute under 10 minutes, the nearest 5 minutes under an hour, and the
    /// nearest 15 minutes from an hour on. An estimate made again as each
    /// item finishes so changes its words only when it moves by a step that
    /// matters at its size, and does not flicker between neighbors.
    static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds >= 60 else { return 0 }
        let minutes = seconds / 60
        let step: Double = minutes < 10 ? 1 : (minutes < 60 ? 5 : 15)
        return (minutes / step).rounded() * step * 60
    }
}
