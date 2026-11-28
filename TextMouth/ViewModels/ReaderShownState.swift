import Foundation

/// What a reader's window shows of where the book is, as one value, so the
/// reader can tell its views of a change only when something they show has
/// changed (audit C3).
///
/// The reader's place moves with every spoken word, eight times a second
/// while a book plays, and the reader used to publish each move, which drew
/// all five of the window's views (the header, the text, the status row, the
/// playback bar, and the window) at 11 ms of the main thread a time. The
/// views show far less than the place: a percentage to a tenth, a time to the
/// second, the heading and page the place is in, whether a bookmark is near,
/// and a window of text that moves when the place nears its edge. The reader
/// builds this value after each refresh of its display mirrors and announces
/// a change only when it differs from the last it announced
/// (`ReaderViewModel.announceShownStateIfChanged()`).
///
/// Everything a view of the window draws from the reader's place is in here,
/// so a value left out would go stale on the screen and to VoiceOver. The
/// tests (`ReaderShownStateTests`) build each label and value of the views
/// from the raw cursor at every step and compare them with what the shown
/// state holds. The sleep timer's countdown is not here: its label observes
/// the timer itself (`SleepTimerStatusLabel`).
struct ReaderShownState: Equatable {
    /// The content unit the window shows: the text area draws only while it
    /// is in range, and a book without headings names its place by the
    /// unit's own title.
    let chapterIndex: Int
    /// The heading the place is in and its number, which the header names.
    let headingPosition: HeadingPosition
    /// How many headings start at or before the place. The headings sheet
    /// marks the current heading under each level filter from the set of
    /// headings behind the place, which this count tracks as the place
    /// crosses each heading, whatever its level or its order in the list.
    let headingsBehind: Int
    /// The status row's percentage, as drawn and spoken: "42.5%".
    let percentText: String
    /// The status row's time left, as drawn: "1:02:03". Its spoken form is
    /// made from the same whole seconds, so it changes with this.
    let timeLeftText: String
    /// The page the place is in, which the status row names.
    let pagePosition: PagePosition
    /// Whether a bookmark is near the place, which the playback bar's
    /// bookmark button names.
    let hasNearbyBookmark: Bool
    /// The text the text area draws.
    let visibleTextWindow: String

    /// What `reader`'s window shows, from the display mirrors the reader has
    /// just brought up to date, and the cursor the bookmark button follows.
    @MainActor
    init(of reader: ReaderViewModel) {
        chapterIndex = reader.displayChapterIndex
        headingPosition = reader.displayHeadingPosition
        headingsBehind = reader.headings.reduce(0) { count, heading in
            heading.startsAtOrBefore(
                chapterIndex: reader.displayChapterIndex,
                characterOffset: reader.displayCharacterOffset
            ) ? count + 1 : count
        }
        percentText = reader.displayFormattedPercentComplete
        timeLeftText = reader.displayFormattedTimeRemaining
        pagePosition = reader.displayPagePosition
        hasNearbyBookmark = reader.hasNearbyBookmark
        visibleTextWindow = reader.displayVisibleTextWindow
    }
}
