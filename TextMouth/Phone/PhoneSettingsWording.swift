import Foundation

/// The words of the phone's Settings screen that the Mac doesn't have, as the
/// iPhone interface spec gives them (under "Settings" and "One vocabulary"),
/// with the changes its outside reviews made on November 7. The Mac's own
/// words are in `PhoneSettingsVocabulary`.
enum PhoneSettingsWording {
    /// The screen's title.
    static var screenTitle: String {
        // Translators: Title of the iPhone's Settings screen.
        InterfaceText.line("common.settings", "Settings")
    }

    // MARK: Navigation

    /// The row choosing what a text book moves by until it has a unit of its
    /// own.
    static var textNavigationUnit: String {
        // Translators: Label and title of the iPhone Settings row that chooses what a text book moves by until it has a unit of its own.
        InterfaceText.line("phoneSettings.textNavigationUnit", "Navigation unit for text books")
    }
    /// The row choosing what an audiobook moves by until it has a unit of its
    /// own.
    static var audioNavigationUnit: String {
        // Translators: Label and title of the iPhone Settings row that chooses what an audiobook moves by until it has a unit of its own.
        InterfaceText.line("phoneSettings.audioNavigationUnit", "Navigation unit for audiobooks")
    }
    /// What both rows do.
    static var navigationUnitHint: String {
        // Translators: Hint of the two iPhone Settings rows that choose a navigation unit, one for text books and one for audiobooks.
        InterfaceText.line("phoneSettings.navigationUnitHint", "What a book of this kind moves by until it has a unit of its own.")
    }

    // MARK: Sleep Timer

    /// The switch that lets a shake start an ended sleep timer again (FR55).
    static var shakeToRestartTimer: String {
        // Translators: Switch in the Sleep Timer section of iPhone Settings: shaking the iPhone soon after a sleep timer ends starts the same timer again.
        InterfaceText.line("phoneSettings.shakeToRestartTimer", "Shake to restart the timer")
    }
    /// What the switch does.
    static var shakeToRestartTimerHint: String {
        // Translators: Hint of the Shake to restart the timer switch in iPhone Settings.
        InterfaceText.line("phoneSettings.shakeToRestartTimerHint", "For a minute after a sleep timer ends, shaking iPhone starts it again.")
    }

    // MARK: Reading

    /// The section holding Follow in Braille.
    static var readingSection: String {
        // Translators: Heading of the iPhone Settings section that holds Follow in Braille.
        InterfaceText.line("phoneSettings.readingSection", "Reading")
    }
    /// What the Braille code row does, spoken after its label and value: the iPhone only reads braille files, so unlike the
    /// Mac's pop-up it says nothing of writing.
    static var brailleCodeHint: String {
        // Translators: The hint of the Braille code row in the iPhone's Settings, which opens the list of braille codes used to read braille files.
        InterfaceText.line("phoneSettings.brailleCodeHint", "The braille code for reading braille files.")
    }
    /// The caption under the Braille code row (FR32): which books it applies to and what a book keeps.
    static var brailleCaption: String {
        // Translators: The caption under the Braille code row in the iPhone's Settings. A book keeps the braille code it was added with.
        InterfaceText.line("phoneSettings.brailleCaption", "TextMouth reads braille files you add from now on with this code. A book keeps the code it was added with.")
    }
    /// The switch that lets Book content follow the speech.
    static var followInBraille: String {
        // Translators: Switch in iPhone Settings: while a book plays, the book's text moves on with the speech, for a braille display.
        InterfaceText.line("phoneSettings.followInBraille", "Follow in Braille")
    }
    /// What Follow in Braille does.
    static var followInBrailleHint: String {
        SentenceWording.joined([
            // Translators: First sentence of the hint of Follow in Braille in iPhone Settings. "Book content" is the name of the element that holds the book's text, as VoiceOver reads it.
            InterfaceText.line("phoneSettings.followInBrailleHint.playing", "While playing, moves Book content on with the speech, even as you read it."),
            // Translators: Last sentence of the hint of Follow in Braille in iPhone Settings.
            InterfaceText.line("phoneSettings.followInBrailleHint.display", "For trying out with a braille display."),
        ])
    }

    // MARK: Statistics and About

    /// The section holding Reading Statistics.
    static var statisticsSection: String {
        // Translators: Heading of the iPhone Settings section that holds the row for Reading Statistics.
        InterfaceText.line("phoneSettings.statisticsSection", "Statistics")
    }
    /// The row that pushes the reading statistics, and the title of what it
    /// pushes.
    static var readingStatistics: String {
        // Translators: Row in iPhone Settings that opens the reading statistics, and the title of the screen it opens.
        InterfaceText.line("phoneSettings.readingStatistics", "Reading Statistics")
    }
    /// The section holding the version and the logs.
    static var aboutSection: String {
        // Translators: Heading of the iPhone Settings section that holds the app's version and its logs.
        InterfaceText.line("phoneSettings.aboutSection", "About")
    }
    /// The row naming the app's version.
    static var version: String {
        // Translators: Label of the iPhone Settings row that names the app's version.
        InterfaceText.line("phoneSettings.version", "Version")
    }
    /// The button that shares the logs.
    static var shareLogs: String {
        // Translators: Button in iPhone Settings that shares TextMouth's recent logs as a text file. The ellipsis means the share sheet opens.
        InterfaceText.line("phoneSettings.shareLogs", "Share Logs…")
    }
    /// What sharing the logs does.
    static var shareLogsHint: String {
        // Translators: Hint of the Share Logs button in iPhone Settings.
        InterfaceText.line("phoneSettings.shareLogsHint", "Shares recent logs as a text file. They hold no book text.")
    }
}
