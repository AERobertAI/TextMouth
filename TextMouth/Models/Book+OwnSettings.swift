import Foundation

// MARK: - A Book's Own Settings

extension Book {
    /// Whether the book keeps a setting of its own in place of the global
    /// one: a voice, speed, or pitch (`hasLocalVoiceSettings`), headings it
    /// skips, what happens at its end, or the unit of a skip forward or
    /// back. A feed item's package that holds one is kept once its file
    /// goes (`FeedItemPackage.holdsListenerState`), and Delete Download and
    /// the library's Remove name it as its "own settings"
    /// (`FeedWording.KeptParts`): one rule for both (REV13 feeds 11).
    var hasOwnSettings: Bool {
        hasLocalVoiceSettings
            || !(skippedHeadingIDs ?? []).isEmpty
            || localEndOfBookBehavior != nil
            || localSkipForwardUnit != nil
            || localSkipBackwardUnit != nil
    }
}
