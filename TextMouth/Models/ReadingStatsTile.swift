import Foundation

// MARK: - Figures

/// Every figure the Stats settings pane shows, read from the statistics at
/// one instant (TODO C07).
///
/// The pane reads them all together each time it refreshes, so its tiles
/// always agree with one another: Today can never exceed This Week or All
/// Time, as it could if each tile read the clock a moment apart.
struct ReadingStatsFigures: Equatable {
    /// Listening time on the local day containing the instant.
    var today: TimeInterval
    /// Listening time over the seven local days ending with that day.
    var thisWeek: TimeInterval
    /// Listening time over all time.
    var allTime: TimeInterval
    /// Consecutive days with more than a minute of listening, through that
    /// day or, while it has none yet, through the day before.
    var currentStreakDays: Int
    /// Books finished in the year containing the instant.
    var booksFinishedThisYear: Int
    /// Books finished ever.
    var booksFinishedAllTime: Int
}

extension ReadingStatsFigures {
    /// The figures `service` gives at `now`. Each listening time includes
    /// the open session's time since its last checkpoint, which the
    /// service's getters add to the saved totals exactly once.
    @MainActor
    init(service: ReadingStatsService, at now: Date) {
        self.init(
            today: service.todayListeningTime(at: now),
            thisWeek: service.thisWeekListeningTime(at: now),
            allTime: service.allTimeListeningTime(at: now),
            currentStreakDays: service.currentStreak(at: now),
            booksFinishedThisYear: service.booksFinishedThisYear(at: now),
            booksFinishedAllTime: service.stats.finishedBooks.count
        )
    }
}

// MARK: - Tiles

/// One figure on the Stats settings pane: a fixed title beside a value
/// that changes as the user listens.
///
/// A tile is identified by the tile itself, never by its value, so when the
/// figures change only the tile's words change: SwiftUI updates each tile
/// in place instead of replacing it, and VoiceOver's cursor stays on the
/// tile the user was reading (TODO C07).
enum ReadingStatsTile: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case allTime
    case currentStreak
    case booksFinishedThisYear
    case booksFinishedAllTime

    /// The tiles under the Listening Time heading, in order.
    static let listeningTime: [ReadingStatsTile] = [.today, .thisWeek, .allTime]

    /// The tiles under the Progress heading, in order.
    static let progress: [ReadingStatsTile] = [.currentStreak, .booksFinishedThisYear, .booksFinishedAllTime]

    /// The tile itself, whatever its figure.
    var id: Self { self }

    /// The title shown beside the tile's value.
    var title: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .allTime: return "All Time"
        case .currentStreak: return "Current Streak"
        case .booksFinishedThisYear: return "Books Finished This Year"
        case .booksFinishedAllTime: return "Books Finished All Time"
        }
    }

    /// The tile's accessibility identifier, "readingStats.today" and so on,
    /// which never changes with its figure.
    var accessibilityIdentifier: String {
        "readingStats.\(rawValue)"
    }

    /// What the tile shows and what VoiceOver speaks for it when the
    /// figures are `figures`.
    func wording(for figures: ReadingStatsFigures) -> ReadingStatsTileWording {
        switch self {
        case .today:
            return .duration(figures.today, spokenAfter: "Listening time today")
        case .thisWeek:
            return .duration(figures.thisWeek, spokenAfter: "Listening time this week")
        case .allTime:
            return .duration(figures.allTime, spokenAfter: "Total listening time")
        case .currentStreak:
            return .count(figures.currentStreakDays, singular: "day", plural: "days") {
                "Current listening streak: \($0)"
            }
        case .booksFinishedThisYear:
            return .count(figures.booksFinishedThisYear, singular: "book", plural: "books") {
                "\($0) finished this year"
            }
        case .booksFinishedAllTime:
            return .count(figures.booksFinishedAllTime, singular: "book", plural: "books") {
                "\($0) finished all time"
            }
        }
    }
}

// MARK: - Wording

/// The words for one tile: the value shown beside its title, and the label
/// VoiceOver speaks, and a braille display shows, for the whole tile.
///
/// Both come from one phrase, so what the screen shows and what VoiceOver
/// says always agree, plural included.
struct ReadingStatsTileWording: Equatable {
    /// The value shown beside the title: "1:05:03", "1 day", "3 books".
    let value: String
    /// What VoiceOver speaks for the tile: "Listening time today: 1 hour,
    /// 5 minutes, 3 seconds", "Current listening streak: 1 day".
    let accessibilityLabel: String

    /// A listening time, shown in digits as hours, minutes, and seconds and
    /// spoken in words after `subject`: "Listening time today: 1 hour,
    /// 5 minutes, 3 seconds". Spoken as digits, "1:05:03" could pass for a
    /// time of day.
    static func duration(_ seconds: TimeInterval, spokenAfter subject: String) -> ReadingStatsTileWording {
        ReadingStatsTileWording(
            value: TimeFormatting.format(seconds),
            accessibilityLabel: "\(subject): \(TimeFormatting.spoken(seconds))"
        )
    }

    /// A count, shown as its count phrase ("1 day", "3 days", from
    /// `CountWording`) and spoken as `spoken` places that same phrase in a
    /// sentence.
    static func count(
        _ count: Int,
        singular: String,
        plural: String,
        spoken: (String) -> String
    ) -> ReadingStatsTileWording {
        let phrase = CountWording.phrase(count, singular: singular, plural: plural)
        return ReadingStatsTileWording(value: phrase, accessibilityLabel: spoken(phrase))
    }
}
