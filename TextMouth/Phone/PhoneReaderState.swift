import Foundation

/// The reader's controls: those on the screen after Back and the title, in
/// VoiceOver's order and the layout's (the spec, under "VoiceOver's order";
/// `screen`), then those under Book Actions (`bookActionItems`, FR51). The
/// screen's controls never appear or vanish while a book is open: only their
/// words change.
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
    /// Adds a bookmark, or removes the one at the place.
    case addBookmark
    /// Opens the Bookmarks sheet.
    case bookmarks
    /// Opens the Headings sheet.
    case headings
    /// Opens the Go To sheet.
    case goTo
    /// Goes back to where the last jump began.
    case returnToPlace
    /// A menu of the book's less frequent actions (FR51): the five below.
    case bookActions
    /// Opens the Search in Book sheet, or says why the book has no text to
    /// search: under Book Actions (FR54).
    case searchInBook
    /// Opens the Sleep Timer sheet.
    case sleepTimer
    /// Opens the Voice & Speed sheet, or an audiobook's Audio Settings.
    case voice
    /// Opens the Book Info sheet.
    case bookInfo
    /// Opens the Export sheet.
    case export
    /// A move back by the unit in force.
    case skipBackward
    /// A move forward by the unit in force.
    case skipForward

    /// Play's row, left to right and in VoiceOver's order: Skip backward
    /// just before Play and Skip forward just after it (FR54, the user's
    /// answer of November 27), as a player's buttons stand.
    static let playRow: [PhoneReaderControl] = [.skipBackward, .play, .skipForward]

    /// The grid's rows under Play, left to right and top to bottom, three to
    /// a row, in VoiceOver's order however the rows break, Add bookmark,
    /// Bookmarks, and Headings together in the second. Previous Heading and
    /// Next Heading are gone for everyone, since Play adjusted by the heading
    /// unit makes their moves (FR54). Book Actions ends the last row, in place
    /// of Search in Book, Sleep Timer, Voice, Book Info, and Export this book,
    /// which it gathers (FR51, FR54).
    static let gridRows: [[PhoneReaderControl]] = [
        [.whereAmI, .navigationUnit, .speed],
        [.addBookmark, .bookmarks, .headings],
        [.goTo, .returnToPlace, .bookActions],
    ]

    /// The controls of the grid under Play, row by row: Where Am I? to Book
    /// Actions.
    static let grid: [PhoneReaderControl] = gridRows.flatMap { $0 }

    /// The reader's controls on the screen, in VoiceOver's order: Book
    /// content, Play's row, the Sleep Timer while a timer runs, and the grid.
    /// The Sleep Timer is the one control that comes and goes (FR51, FR55):
    /// with no timer it lives under Book Actions, and while one runs it shows
    /// under Play too, its value the time left.
    static func screen(timerRuns: Bool) -> [PhoneReaderControl] {
        [.bookContent] + playRow + (timerRuns ? [.sleepTimer] : []) + grid
    }

    /// Whether the control is one of the two skips, Skip backward and Skip
    /// forward, which Settings' "Hide skip buttons from VoiceOver" hides.
    var isSkip: Bool {
        self == .skipBackward || self == .skipForward
    }

    /// Whether VoiceOver passes over the control: the skips, while Settings'
    /// "Hide skip buttons from VoiceOver" (`hidingSkips`) is on, since
    /// adjusting Play makes the same moves (FR49, FR54). The switch is off by
    /// default, so VoiceOver reaches them. Hidden, they stay on screen for
    /// touch, and for Voice Control and Switch Control, which run without
    /// VoiceOver.
    func isHiddenFromVoiceOver(hidingSkips: Bool) -> Bool {
        hidingSkips && isSkip
    }

    /// The reader's controls VoiceOver reaches, in its order: the screen's,
    /// less those it passes over while it runs.
    static func voiceOverOrder(timerRuns: Bool, voiceOverRuns: Bool, hidingSkips: Bool) -> [PhoneReaderControl] {
        screen(timerRuns: timerRuns).filter { !(voiceOverRuns && $0.isHiddenFromVoiceOver(hidingSkips: hidingSkips)) }
    }

    /// The items of the Book Actions menu, in its order (FR51): the book's
    /// less frequent actions, each opening its sheet as its button did, Search
    /// in Book first (FR54: the menu is the iPhone's equivalent of the Mac's
    /// toolbar, the user's answer of November 27).
    static let bookActionItems: [PhoneReaderControl] = [.searchInBook, .sleepTimer, .voice, .bookInfo, .export]

    /// Where VoiceOver's focus goes back to, for a sheet that `control`
    /// opened as it closes, or for the control VoiceOver was on as it leaves
    /// the screen: `control` while it is still on the screen, and Play when
    /// it is not. Only the Sleep Timer under Play comes and goes (FR52): a
    /// timer turned off in its sheet, or one that ran out under VoiceOver's
    /// focus, would otherwise leave focus on a control that is gone, and
    /// VoiceOver would drop it at the top of the screen.
    static func focusTarget(returningTo control: PhoneReaderControl, timerRuns: Bool) -> PhoneReaderControl {
        screen(timerRuns: timerRuns).contains(control) ? control : .play
    }

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
        case .addBookmark: return .addBookmark
        case .bookmarks: return .bookmarks
        case .headings: return .headings
        case .searchInBook: return .searchInBook
        case .goTo: return .goTo
        case .returnToPlace: return .returnToPlace
        case .bookActions: return .bookActions
        case .sleepTimer: return .sleepTimer
        case .voice: return .voice
        case .bookInfo: return .bookInfo
        case .export: return .export
        case .skipBackward: return .skipBackward
        case .skipForward: return .skipForward
        }
    }

    /// What adjusting the control does, for the three adjustable ones: Play,
    /// Navigation unit, and Speed; nil for the rest, which a swipe up or down
    /// leaves alone. The Sleep Timer under Play is not adjustable: its Reset
    /// Timer and Cancel Timer are actions, picked and then done (FR55).
    var adjustment: PhoneControlAdjustment? {
        switch self {
        case .play: return .move
        case .navigationUnit: return .unit
        case .speed: return .speed
        default: return nil
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
        case .export: return .export
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
    /// The page at the place, "Page 112 of 300", for Go To's value (FR50);
    /// "" in a book of fewer than two pages. Unlike Where Am I?'s page, it
    /// doesn't wait on the reader screen's page setting: Go To goes to pages.
    var goToPage: String = ""
    /// The time at the place, as Go To's Time field starts ("1:02:03"): the
    /// recording's for an audiobook, else at the book's listening speed
    /// (FR50).
    var goToTime: String = ""
}
