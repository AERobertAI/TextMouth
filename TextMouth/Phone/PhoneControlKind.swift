import Foundation

/// Each of the reader's own controls, in the spec's VoiceOver order: what the
/// focus rules and the focus registry name a control by. The system's Back
/// button and the title are not the reader's controls: VoiceOver wanders onto
/// them by itself, as a screen arrives.
enum PhoneControlKind: Hashable, Sendable, CaseIterable {
    /// Book content: the text around the place.
    case bookContent
    /// Play, or Pause.
    case play
    /// The unit the moves go by.
    case navigationUnit
    /// Moves back by the unit.
    case skipBackward
    /// Moves forward by the unit.
    case skipForward
    /// Moves to the previous heading, whatever the unit.
    case previousHeading
    /// Moves to the next heading, whatever the unit.
    case nextHeading
    /// The speed.
    case speed
    /// Where Am I?
    case whereAmI
    /// Adds a bookmark at the place.
    case addBookmark
    /// The Bookmarks sheet.
    case bookmarks
    /// The Headings sheet.
    case headings
    /// The Search in Book sheet.
    case searchInBook
    /// The Go To sheet.
    case goTo
    /// Return, to the place before the last jump.
    case returnToPlace
    /// The Sleep Timer sheet.
    case sleepTimer
    /// The Voice & Speed sheet, or Audio Settings for an audiobook.
    case voice
    /// Book Info.
    case bookInfo
}
