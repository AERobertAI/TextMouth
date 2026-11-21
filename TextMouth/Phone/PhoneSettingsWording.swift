import Foundation

/// The words of the phone's Settings screen that the Mac doesn't have, as the
/// iPhone interface spec gives them (under "Settings" and "One vocabulary"),
/// with the changes its outside reviews made on November 7. The Mac's own
/// words are in `PhoneSettingsVocabulary`.
enum PhoneSettingsWording {
    /// The screen's title.
    static var screenTitle: String {
        // Translators: Title of the iPhone's Settings screen.
        String(localized: "Settings")
    }

    // MARK: Navigation

    /// The row choosing what a text book moves by until it has a unit of its
    /// own.
    static var textNavigationUnit: String {
        // Translators: Label and title of the iPhone Settings row that chooses what a text book moves by until it has a unit of its own.
        String(localized: "Navigation unit for text books")
    }
    /// The row choosing what an audiobook moves by until it has a unit of its
    /// own.
    static var audioNavigationUnit: String {
        // Translators: Label and title of the iPhone Settings row that chooses what an audiobook moves by until it has a unit of its own.
        String(localized: "Navigation unit for audiobooks")
    }
    /// What both rows do.
    static var navigationUnitHint: String {
        // Translators: Hint of the two iPhone Settings rows that choose a navigation unit, one for text books and one for audiobooks.
        String(localized: "What a book of this kind moves by until it has a unit of its own.")
    }

    // MARK: Reading

    /// The section holding Follow in Braille.
    static var readingSection: String {
        // Translators: Heading of the iPhone Settings section that holds Follow in Braille.
        String(localized: "Reading")
    }
    /// The switch that lets Book content follow the speech.
    static var followInBraille: String {
        // Translators: Switch in iPhone Settings: while a book plays, the book's text moves on with the speech, for a braille display.
        String(localized: "Follow in Braille")
    }
    /// What Follow in Braille does.
    static var followInBrailleHint: String {
        SentenceWording.joined([
            // Translators: First sentence of the hint of Follow in Braille in iPhone Settings. "Book content" is the name of the element that holds the book's text, as VoiceOver reads it.
            String(localized: "While playing, moves Book content on with the speech, even as you read it."),
            // Translators: Last sentence of the hint of Follow in Braille in iPhone Settings.
            String(localized: "For trying out with a braille display."),
        ])
    }

    // MARK: Statistics and About

    /// The section holding Reading Statistics.
    static var statisticsSection: String {
        // Translators: Heading of the iPhone Settings section that holds the row for Reading Statistics.
        String(localized: "Statistics")
    }
    /// The row that pushes the reading statistics, and the title of what it
    /// pushes.
    static var readingStatistics: String {
        // Translators: Row in iPhone Settings that opens the reading statistics, and the title of the screen it opens.
        String(localized: "Reading Statistics")
    }
    /// The section holding the version and the logs.
    static var aboutSection: String {
        // Translators: Heading of the iPhone Settings section that holds the app's version and its logs.
        String(localized: "About")
    }
    /// The row naming the app's version.
    static var version: String {
        // Translators: Label of the iPhone Settings row that names the app's version.
        String(localized: "Version")
    }
    /// The button that shares the logs.
    static var shareLogs: String {
        // Translators: Button in iPhone Settings that shares TextMouth's recent logs as a text file. The ellipsis means the share sheet opens.
        String(localized: "Share Logs…")
    }
    /// What sharing the logs does.
    static var shareLogsHint: String {
        // Translators: Hint of the Share Logs button in iPhone Settings.
        String(localized: "Shares recent logs as a text file. They hold no book text.")
    }
}
