import Foundation

/// The words of the phone's Settings screen that the Mac doesn't have, as the
/// iPhone interface spec gives them (under "Settings" and "One vocabulary"),
/// with the changes its outside reviews made on November 7. The Mac's own
/// words are in `PhoneSettingsVocabulary`.
enum PhoneSettingsWording {
    /// The screen's title.
    static let screenTitle = "Settings"

    // MARK: Navigation

    /// The row choosing what a text book moves by until it has a unit of its
    /// own.
    static let textNavigationUnit = "Navigation unit for text books"
    /// The row choosing what an audiobook moves by until it has a unit of its
    /// own.
    static let audioNavigationUnit = "Navigation unit for audiobooks"
    /// What both rows do.
    static let navigationUnitHint = "What a book of this kind moves by until it has a unit of its own."

    // MARK: Reading

    /// The section holding Follow in Braille.
    static let readingSection = "Reading"
    /// The switch that lets Book content follow the speech.
    static let followInBraille = "Follow in Braille"
    /// What Follow in Braille does.
    static let followInBrailleHint =
        "While the book plays, moves Book content on with the speech, even while you're reading it. "
        + "For trying out with a braille display."

    // MARK: Statistics and About

    /// The section holding Reading Statistics.
    static let statisticsSection = "Statistics"
    /// The row that pushes the reading statistics, and the title of what it
    /// pushes.
    static let readingStatistics = "Reading Statistics"
    /// The section holding the version and the logs.
    static let aboutSection = "About"
    /// The row naming the app's version.
    static let version = "Version"
    /// The button that shares the logs.
    static let shareLogs = "Share Logs…"
    /// What sharing the logs does.
    static let shareLogsHint = "Shares TextMouth's recent logs as a text file. They hold no book text."
}
