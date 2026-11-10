import Foundation

/// The reader's elements after Back and the title, in VoiceOver's order and
/// the layout's (the spec, under "VoiceOver's order"). They never appear or
/// vanish while a book is open: only their words change.
enum PhoneReaderControl: CaseIterable, Hashable, Sendable {
    /// The book's text, how a braille reader reads the book.
    case bookContent
    /// Play or Pause; adjusting it moves by the unit in force.
    case play
    /// The place, as a value, and the Mac's spoken summary.
    case whereAmI
    /// What Play and the skip buttons move by.
    case navigationUnit
    /// The book's speed.
    case speed
    /// A move to the heading before.
    case previousHeading
    /// A move to the next heading.
    case nextHeading
    /// Adds a bookmark, or removes the one at the place.
    case addBookmark
    /// Opens the Bookmarks sheet.
    case bookmarks
    /// Opens the Headings sheet.
    case headings
    /// Opens the Search in Book sheet, or says why the book has no text to
    /// search.
    case searchInBook
    /// Opens the Go To sheet.
    case goTo
    /// Goes back to where the last jump began.
    case returnToPlace
    /// Opens the Sleep Timer sheet.
    case sleepTimer
    /// Opens the Voice & Speed sheet, or an audiobook's Audio Settings.
    case voice
    /// Opens the Book Info sheet.
    case bookInfo
    /// A move back by the unit in force.
    case skipBackward
    /// A move forward by the unit in force.
    case skipForward

    /// The controls of the grid under Play, row by row, three to a row:
    /// Where Am I? to Skip forward.
    static let grid: [PhoneReaderControl] = Array(allCases.drop { $0 != .whereAmI })

    /// The kind `PhoneFocusRegistry` knows the control by, for focus on
    /// arrival and on return from a sheet: every control has one, so a
    /// landing on any of them counts as the listener's in `PhoneFocusPolicy`.
    var focusKind: PhoneControlKind {
        switch self {
        case .bookContent: return .bookContent
        case .play: return .play
        case .whereAmI: return .whereAmI
        case .navigationUnit: return .navigationUnit
        case .speed: return .speed
        case .previousHeading: return .previousHeading
        case .nextHeading: return .nextHeading
        case .addBookmark: return .addBookmark
        case .bookmarks: return .bookmarks
        case .headings: return .headings
        case .searchInBook: return .searchInBook
        case .goTo: return .goTo
        case .returnToPlace: return .returnToPlace
        case .sleepTimer: return .sleepTimer
        case .voice: return .voice
        case .bookInfo: return .bookInfo
        case .skipBackward: return .skipBackward
        case .skipForward: return .skipForward
        }
    }

    /// The sheet the control opens, if it opens one.
    var sheet: PhoneReaderSheet? {
        switch self {
        case .navigationUnit: return .navigationUnit
        case .bookmarks: return .bookmarks
        case .headings: return .headings
        case .searchInBook: return .search
        case .goTo: return .goTo
        case .sleepTimer: return .sleepTimer
        case .voice: return .voice
        case .bookInfo: return .bookInfo
        default: return nil
        }
    }
}

/// What Where Am I?'s value is made of, as the reader stands (the spec, under
/// "Where Am I?"): "The Battle, 12 minutes remaining in this heading, Page 112
/// of 300, 30 percent, 3 hours remaining".
struct PhoneWhereAmIParts: Equatable, Sendable {
    /// The heading being read, the Mac's location title; nil when there's
    /// none to name.
    var heading: String?
    /// The time left in that heading; nil when it spans nothing to measure.
    var remainingInHeading: TimeInterval?
    /// "Page 112 of 300", or "" while the reader screen's page setting is off
    /// or the book has fewer than two pages.
    var pageLabel: String
    /// An audiobook's place in its recording; nil for a text book.
    var timeIntoRecording: TimeInterval?
    /// How far through the book the place is, from 0 to 100.
    var percentComplete: Double
    /// The time left in the book.
    var timeRemaining: TimeInterval
    /// The speed the times count at, when the setting names it.
    var speed: ReaderTimeWording.ListeningSpeed?
    /// Whether the book rests at its end, finished.
    var isFinished: Bool
}

/// Everything the reader's controls say, for one moment of one book: a plain
/// value, so `PhoneReaderControls` can be tested on the Mac for every state.
///
/// `PhoneReaderModel` builds it from the reader's real cursor, once per turn
/// of the main queue, however many times VoiceOver asks (the engineering
/// review's F15).
struct PhoneReaderState: Equatable {
    /// The book's title.
    var bookTitle: String
    /// Whether the book is still loading.
    var isLoading: Bool
    /// Why the book couldn't load, or nil.
    var loadFailure: String?
    /// Whether the book plays, by the Mac's rule for Play: waiting counts.
    var isPlaying: Bool
    /// Whether it's an audiobook.
    var isAudioBook: Bool
    /// Whether it's an audiobook with a transcript, whose text Book content
    /// shows like any book's.
    var hasTranscript: Bool
    /// The unit Play, the skip buttons, and the AirPods move by.
    var unit: SkipUnit
    /// What the last paused move said, which Play's value holds until Play
    /// or the next move; nil when there's none.
    var moveWords: String?
    /// Whether Where Am I?'s spoken summary speaks now.
    var isWhereAmISpeaking: Bool
    /// What Where Am I?'s value says.
    var whereAmI: PhoneWhereAmIParts
    /// A text book's speed.
    var wordsPerMinute: Double
    /// An audiobook's speed, as a multiple of its recording's.
    var audioSpeed: Double
    /// Whether the place is near a bookmark, which Add bookmark then removes.
    var isNearBookmark: Bool
    /// How many bookmarks the book has.
    var bookmarkCount: Int
    /// The heading at the place, and its number among the book's headings.
    var headingPosition: HeadingPosition
    /// The sleep timer's status as the Mac speaks it, or "" with no timer.
    var sleepTimerStatus: String
}
