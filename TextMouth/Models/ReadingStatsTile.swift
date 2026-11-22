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
    /// Books finished in the year containing the instant, each once (TODO
    /// P07).
    var booksFinishedThisYear: Int
    /// Books finished ever, each once (TODO P07).
    var booksFinishedAllTime: Int
    /// Books finished in the year containing the instant, by kind (FR03).
    var booksFinishedThisYearByKind = FinishedBookCounts()
    /// Books finished ever, by kind (FR03).
    var booksFinishedAllTimeByKind = FinishedBookCounts()
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
            booksFinishedAllTime: service.booksFinishedAllTime,
            booksFinishedThisYearByKind: service.booksFinishedThisYearByKind(at: now),
            booksFinishedAllTimeByKind: service.booksFinishedAllTimeByKind
        )
    }
}

// MARK: - Books Finished by Kind

/// Books finished, counted by kind (FR03): text books, audiobooks, and
/// podcast episodes. A book whose kind is not known, which only a book
/// finished before TextMouth recorded kinds can be, counts in none of
/// them, so a total may hold more than these three.
struct FinishedBookCounts: Equatable {
    var textBooks = 0
    var audiobooks = 0
    var episodes = 0

    /// Counts given directly.
    init(textBooks: Int = 0, audiobooks: Int = 0, episodes: Int = 0) {
        self.textBooks = textBooks
        self.audiobooks = audiobooks
        self.episodes = episodes
    }

    /// The counts of `kinds`, a book whose kind is not known (nil) counting
    /// in none.
    init(kinds: [FinishedBookKind?]) {
        for kind in kinds {
            switch kind {
            case .text?: textBooks += 1
            case .audiobook?: audiobooks += 1
            case .episode?: episodes += 1
            case nil: break
            }
        }
    }

    /// `count` text books: "1 text book", "4 text books".
    private static func textBooksPhrase(_ count: Int) -> String {
        // Translators: A count of finished text books, one item of the Stats pane's breakdown of finished books by kind, such as "4 text books". %lld is the number of books.
        InterfaceText.line("finishedBookCounts.textBooksPhrase", "\(number: count) text books")
    }

    /// `count` audiobooks: "1 audiobook", "2 audiobooks".
    private static func audiobooksPhrase(_ count: Int) -> String {
        // Translators: A count of finished audiobooks, one item of the Stats pane's breakdown of finished books by kind, such as "2 audiobooks". %lld is the number of books.
        InterfaceText.line("finishedBookCounts.audiobooksPhrase", "\(number: count) audiobooks")
    }

    /// `count` podcast episodes: "1 podcast episode".
    private static func podcastEpisodesPhrase(_ count: Int) -> String {
        // Translators: A count of finished podcast episodes, one item of the Stats pane's breakdown of finished books by kind, such as "1 podcast episode". %lld is the number of episodes.
        InterfaceText.line("finishedBookCounts.podcastEpisodesPhrase", "\(number: count) podcast episodes")
    }

    /// `count` books of no known kind: "1 other book".
    private static func otherBooksPhrase(_ count: Int) -> String {
        // Translators: A count of finished books of no known kind, one item of the Stats pane's breakdown of finished books by kind, such as "1 other book". %lld is the number of books.
        InterfaceText.line("finishedBookCounts.otherBooksPhrase", "\(number: count) other books")
    }

    /// How many books of a known kind there are.
    var known: Int {
        textBooks + audiobooks + episodes
    }

    /// The counts of `total` books as a listener hears them: each kind with
    /// any books, in a fixed order, and the books of no known kind last, as
    /// "other books", joined as a list is spoken: "4 text books, 2
    /// audiobooks, and 1 podcast episode". Nil when there are no books, or
    /// no kind is known, when the counts would say no more than `total`.
    func breakdown(of total: Int) -> String? {
        guard total > 0, known > 0 else { return nil }
        // Each kind with any books, in the fixed order, as its own plural phrase.
        let parts = [
            (textBooks, Self.textBooksPhrase),
            (audiobooks, Self.audiobooksPhrase),
            (episodes, Self.podcastEpisodesPhrase),
            (max(0, total - known), Self.otherBooksPhrase),
        ]
        .filter { count, _ in count > 0 }
        .map { count, phrase in phrase(count) }
        return CountWording.list(parts)
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
        case .today:
            // Translators: Title of the Stats pane's tile showing the listening time of today.
            return InterfaceText.line("readingStatsTile.title.today", "Today")
        case .thisWeek:
            // Translators: Title of the Stats pane's tile showing the listening time of this week.
            return InterfaceText.line("readingStatsTile.title.thisWeek", "This Week")
        case .allTime:
            // Translators: Title of the Stats pane's tile showing the total listening time.
            return InterfaceText.line("readingStatsTile.title.allTime", "All Time")
        case .currentStreak:
            // Translators: Title of the Stats pane's tile showing how many days in a row the user has listened.
            return InterfaceText.line("readingStatsTile.title.currentStreak", "Current Streak")
        case .booksFinishedThisYear:
            // Translators: Title of the Stats pane's tile showing how many books were finished this year.
            return InterfaceText.line("readingStatsTile.title.booksFinishedThisYear", "Books Finished This Year")
        case .booksFinishedAllTime:
            // Translators: Title of the Stats pane's tile showing how many books were ever finished.
            return InterfaceText.line("readingStatsTile.title.booksFinishedAllTime", "Books Finished All Time")
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
            // Translators: What VoiceOver says before the listening time of today on the Stats pane; a colon and the time follow.
            return .duration(figures.today, spokenAfter: InterfaceText.line("readingStatsTile.wording.today", "Listening time today"))
        case .thisWeek:
            // Translators: What VoiceOver says before the listening time of this week on the Stats pane; a colon and the time follow.
            return .duration(figures.thisWeek, spokenAfter: InterfaceText.line("readingStatsTile.wording.thisWeek", "Listening time this week"))
        case .allTime:
            // Translators: What VoiceOver says before the total listening time on the Stats pane; a colon and the time follow.
            return .duration(figures.allTime, spokenAfter: InterfaceText.line("readingStatsTile.wording.allTime", "Total listening time"))
        case .currentStreak:
            return .streak(figures.currentStreakDays)
        case .booksFinishedThisYear:
            let total = figures.booksFinishedThisYear
            // Translators: What VoiceOver says for the Stats pane's tile of books finished this year; a colon and the count of each kind may follow. %lld is the number of books.
            return .books(total, byKind: figures.booksFinishedThisYearByKind, spoken: InterfaceText.line("readingStatsTile.wording.booksFinishedThisYear", "\(number: total) books finished this year"))
        case .booksFinishedAllTime:
            let total = figures.booksFinishedAllTime
            // Translators: What VoiceOver says for the Stats pane's tile of books finished in all, the library's whole history; a colon and the count of each kind may follow. %lld is the number of books.
            return .books(total, byKind: figures.booksFinishedAllTimeByKind, spoken: InterfaceText.line("readingStatsTile.wording.booksFinishedAllTime", "\(number: total) books finished all time"))
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
    /// A line shown under the value, which the spoken label holds too, or
    /// nil for none: the books finished of each kind.
    var detail: String? = nil

    /// A listening time, shown in digits as hours, minutes, and seconds and
    /// spoken in words after `subject`: "Listening time today: 1 hour,
    /// 5 minutes, 3 seconds". Spoken as digits, "1:05:03" could pass for a
    /// time of day.
    static func duration(_ seconds: TimeInterval, spokenAfter subject: String) -> ReadingStatsTileWording {
        ReadingStatsTileWording(
            value: TimeFormatting.format(seconds),
            accessibilityLabel: SentenceWording.labelled(subject, TimeFormatting.spoken(seconds))
        )
    }

    /// The current streak of `days` days, shown as the count ("1 day", "3
    /// days") and spoken after "Current listening streak": the same count,
    /// so the screen and VoiceOver agree, plural included.
    static func streak(_ days: Int) -> ReadingStatsTileWording {
        // Translators: A count of days in a row, the Stats pane's current listening streak, such as "3 days". %lld is the number of days.
        let phrase = InterfaceText.line("common.countDays", "\(number: days) days")
        // Translators: What VoiceOver says before the count of days of the current listening streak on the Stats pane; a colon and the count follow.
        let subject = InterfaceText.line("readingStatsTile.streak", "Current listening streak")
        return ReadingStatsTileWording(value: phrase, accessibilityLabel: SentenceWording.labelled(subject, phrase))
    }

    /// Books finished in a period: `total`, shown as its phrase ("7 books")
    /// with the count of each kind under it when any kind is known, and
    /// spoken as `spoken`, the sentence that says the total and the period
    /// ("7 books finished this year"), then the count of each kind: "7 books
    /// finished this year: 4 text books, 2 audiobooks, and 1 podcast
    /// episode". With no kind known, only the total is shown and spoken.
    static func books(_ total: Int, byKind counts: FinishedBookCounts, spoken: String) -> ReadingStatsTileWording {
        let breakdown = counts.breakdown(of: total)
        return ReadingStatsTileWording(
            value: CountWording.books(total),
            accessibilityLabel: breakdown.map { SentenceWording.labelled(spoken, $0) } ?? spoken,
            detail: breakdown
        )
    }
}
