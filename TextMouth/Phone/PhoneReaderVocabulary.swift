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
        PlaybackControlsWording.skipBackward(unit: unit.title)
    }

    /// The skip forward button's label: "Skip forward: Sentence".
    static func skipForward(by unit: SkipUnit) -> String {
        PlaybackControlsWording.skipForward(unit: unit.title)
    }

    /// The unit picker's label.
    static var navigationUnit: String { PlaybackControlsWording.unitLabel }

    /// The bookmark button's label away from a bookmark.
    static var addBookmark: String { PlaybackControlsWording.addBookmark }

    /// The bookmark button's label at a bookmark, which it removes.
    static var removeBookmark: String { PlaybackControlsWording.removeBookmark }

    /// A text book's speed as VoiceOver reads it: "200 words per minute".
    static func wordsPerMinute(_ wordsPerMinute: Double) -> String {
        PlaybackControlsWording.wordsPerMinute(Int(wordsPerMinute))
    }

    // MARK: The Reader's Toolbar and States (ReaderView)

    /// The Return button's label.
    static var returnToPreviousPosition: String { ReaderViewWording.returnSpoken }

    /// The Headings button's title.
    static var headings: String { ReaderViewWording.headingsTitle }

    /// The Bookmarks button's title.
    static var bookmarks: String { ReaderViewWording.bookmarksTitle }

    /// The Sleep Timer button's title.
    static var sleepTimer: String { ReaderViewWording.sleepTimerTitle }

    /// What the reader shows while the book loads.
    static var loadingBook: String { ReaderViewWording.loadingBook }

    /// What VoiceOver calls the reader while `title` loads: "Loading
    /// Moby-Dick".
    static func loading(_ title: String) -> String {
        ReaderViewWording.loading(title: title)
    }

    // MARK: Where Am I?'s Parts (ReaderViewModel+WhereAmI)

    /// The brief summary's percent: "30 percent".
    static func percent(_ percentComplete: Double) -> String {
        // Rounded half to even, as the format "%.0f" the Mac's summaries use does.
        let rounded = Int(percentComplete.rounded(.toNearestOrEven))
        // Translators: Part of the iPhone reader's brief Where Am I? summary: how far through the book the place is. %lld is the whole percent.
        return InterfaceText.line("common.countPercent", "\(number: rounded) percent")
    }

    /// The summaries' time left in the book, with the speed it counts at when
    /// the setting names it: "3 hours remaining".
    static func remaining(_ timeRemaining: TimeInterval, speed: ReaderTimeWording.ListeningSpeed?) -> String {
        ReaderTimeWording.remainingSpoken(TimeFormatting.spoken(timeRemaining), speed: speed)
    }

    /// The full summary's time left in the heading being read: "12 minutes
    /// remaining in this heading".
    static func remainingInHeading(_ timeRemaining: TimeInterval) -> String {
        // The Mac's full summary says the same words (`ReaderViewModel.whereAmIFull`), so the key is shared.
        // Translators: Part of the full Where Am I? summary: the time left in the heading being read. %@ is the time in words, such as "12 minutes".
        InterfaceText.line("common.valueRemainingInThisHeading", "\(TimeFormatting.spoken(timeRemaining)) remaining in this heading")
    }
}
