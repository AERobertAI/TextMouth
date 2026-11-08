import Foundation

/// The Mac's own words for the reader that sit inline in a Mac view or in a
/// shared function's body, held here for the iPhone's reader (the spec, under
/// "One vocabulary"). The Mac's views stay as they are: each word here is
/// pinned word for word to the Mac's source by `PhoneReaderVocabularyTests`,
/// so the two apps can't drift apart unnoticed.
///
/// A word the Mac exposes as a shared constant or function, such as
/// `ReaderTextArea.accessibilityLabel` or `AudioSpeed.spokenLabel(for:)`, is
/// called where it's needed, never copied here.
enum PhoneReaderVocabulary {
    // MARK: The Playback Bar (PlaybackControlsView)

    /// The skip backward button's label, naming the unit it moves by:
    /// "Skip backward: Sentence".
    static func skipBackward(by unit: SkipUnit) -> String {
        "Skip backward: \(unit.rawValue)"
    }

    /// The skip forward button's label: "Skip forward: Sentence".
    static func skipForward(by unit: SkipUnit) -> String {
        "Skip forward: \(unit.rawValue)"
    }

    /// The unit picker's label.
    static let navigationUnit = "Navigation unit"

    /// The bookmark button's label away from a bookmark.
    static let addBookmark = "Add bookmark"

    /// The bookmark button's label at a bookmark, which it removes.
    static let removeBookmark = "Remove bookmark"

    /// A text book's speed as VoiceOver reads it: "200 words per minute".
    static func wordsPerMinute(_ wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute)) words per minute"
    }

    // MARK: The Reader's Toolbar and States (ReaderView)

    /// The Return button's label.
    static let returnToPreviousPosition = "Return to previous reading position"

    /// The Headings button's title.
    static let headings = "Headings"

    /// The Bookmarks button's title.
    static let bookmarks = "Bookmarks"

    /// The Sleep Timer button's title.
    static let sleepTimer = "Sleep Timer"

    /// What the reader shows while the book loads.
    static let loadingBook = "Loading book..."

    /// What VoiceOver calls the reader while `title` loads: "Loading
    /// Moby-Dick".
    static func loading(_ title: String) -> String {
        "Loading \(title)"
    }

    // MARK: Where Am I?'s Parts (ReaderViewModel+WhereAmI)

    /// The brief summary's percent: "30 percent".
    static func percent(_ percentComplete: Double) -> String {
        String(format: "%.0f percent", percentComplete)
    }

    /// The summaries' time left in the book, with the speed it counts at when
    /// the setting names it: "3 hours remaining".
    static func remaining(_ timeRemaining: TimeInterval, speed: ReaderTimeWording.ListeningSpeed?) -> String {
        "\(TimeFormatting.spoken(timeRemaining)) remaining\(ReaderTimeWording.spokenSpeed(speed))"
    }

    /// The full summary's time left in the heading being read: "12 minutes
    /// remaining in this heading".
    static func remainingInHeading(_ timeRemaining: TimeInterval) -> String {
        "\(TimeFormatting.spoken(timeRemaining)) remaining in this heading"
    }
}
