import SwiftUI
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import os.log

/// The window of a long chapter's text that the reader shows: where it is
/// cut (`bounds(in:around:maximumLength:)`) and when it moves
/// (`shouldRefresh`).
enum VisibleTextWindowPolicy {
    /// Whether the window must be cut again for `offset`: always for a
    /// chapter shown whole, and otherwise when the window shows another
    /// chapter or `offset` has come within `guardFraction` of the window's
    /// length of either edge.
    static func shouldRefresh(
        chapterTextLength: Int,
        maximumDisplayLength: Int,
        cachedChapterIndex: Int?,
        windowStart: Int?,
        windowEnd: Int?,
        chapterIndex: Int,
        offset: Int,
        guardFraction: Double
    ) -> Bool {
        guard chapterTextLength > maximumDisplayLength else { return true }
        guard let cachedChapterIndex, let windowStart, let windowEnd else { return true }
        guard cachedChapterIndex == chapterIndex else { return true }

        let guardSize = max(1, Int(Double(max(windowEnd - windowStart, 0)) * guardFraction))
        let lowerBound = windowStart + guardSize
        let upperBound = max(lowerBound, windowEnd - guardSize)
        return offset < lowerBound || offset > upperBound
    }

    /// Where the window of `text` shown around `offset` begins and ends, in
    /// UTF-16 offsets: the whole text when it is no longer than
    /// `maximumLength`; otherwise about `maximumLength` characters centered
    /// on `offset`, as nearly as the text's ends allow.
    ///
    /// The window always holds `offset`, and it begins and ends on whole
    /// words, which VoiceOver and a braille display read there (TODO A11).
    /// Each edge the window cuts moves inward, by at most a quarter of the
    /// window and never past `offset`: to a paragraph break, so the window
    /// keeps whole paragraphs where it can; else to a line break; else
    /// nowhere, when the cut falls between two words; else to a space. Only
    /// a quarter of the window with no space in it, as in a language
    /// written without spaces, leaves an edge where it was cut, between two
    /// whole characters.
    ///
    /// The window used to begin after the first paragraph break anywhere in
    /// it, and to end at the last one after that, or where it was cut. In
    /// text whose paragraphs end in single line breaks, one blank line near
    /// the window's end left a window of a few words after the reading
    /// position, ending mid-word.
    static func bounds(in text: String, around offset: Int, maximumLength: Int) -> Range<Int> {
        let length = text.utf16Length
        guard length > maximumLength else { return 0..<length }

        let cursor = min(max(offset, 0), length)
        let half = maximumLength / 2
        let center = min(max(cursor, half), length - half)
        // How far an edge may move inward to reach a boundary.
        let reach = maximumLength / 4
        var start = center - half
        var end = center + half
        if start > 0 {
            start = startBoundary(in: text, cutAt: start, limit: min(cursor, start + reach))
        }
        if end < length {
            end = endBoundary(in: text, cutAt: end, limit: max(cursor, end - reach))
        }
        // However the boundaries fell, the window holds the reading position.
        return min(start, cursor)..<max(end, cursor)
    }

    /// Where a window cut at the UTF-16 offset `cut` begins, moving no
    /// further than `limit`: just after the first paragraph break, else line
    /// break, before `limit`; else at the cut, when it falls between words;
    /// else just after the first space before `limit`; else at the cut. A
    /// cut inside a character moves on to the character's end first.
    private static func startBoundary(in text: String, cutAt cut: Int, limit: Int) -> Int {
        var cutIndex = text.index(atUTF16Offset: cut)
        if text.utf16Offset(of: cutIndex) < cut, cutIndex < text.endIndex {
            cutIndex = text.index(after: cutIndex)
        }
        let limitIndex = text.index(atUTF16Offset: limit)
        guard limitIndex > cutIndex else { return text.utf16Offset(of: cutIndex) }
        let searched = cutIndex..<limitIndex
        if let lineBreak = text.range(of: "\n\n", range: searched) ?? text.range(of: "\n", range: searched) {
            return text.utf16Offset(of: lineBreak.upperBound)
        }
        guard !isBetweenWords(text, at: cutIndex) else { return text.utf16Offset(of: cutIndex) }
        let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, range: searched)
        return text.utf16Offset(of: space?.upperBound ?? cutIndex)
    }

    /// Where a window cut at the UTF-16 offset `cut` ends, moving back no
    /// further than `limit`: where the last paragraph break, else line
    /// break, after `limit` begins; else at the cut, when it falls between
    /// words; else where the last space after `limit` begins; else at the
    /// cut. A cut inside a character moves back to the character's start
    /// first.
    private static func endBoundary(in text: String, cutAt cut: Int, limit: Int) -> Int {
        let cutIndex = text.index(atUTF16Offset: cut)
        let limitIndex = text.index(atUTF16Offset: limit)
        guard cutIndex > limitIndex else { return text.utf16Offset(of: cutIndex) }
        let searched = limitIndex..<cutIndex
        if let lineBreak = text.range(of: "\n\n", options: .backwards, range: searched)
            ?? text.range(of: "\n", options: .backwards, range: searched) {
            return text.utf16Offset(of: lineBreak.lowerBound)
        }
        guard !isBetweenWords(text, at: cutIndex) else { return text.utf16Offset(of: cutIndex) }
        let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: searched)
        return text.utf16Offset(of: space?.lowerBound ?? cutIndex)
    }

    /// Whether a cut at `index` falls between two words: at either end of
    /// `text`, or beside whitespace.
    private static func isBetweenWords(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return true }
        return text[text.index(before: index)].isWhitespace || text[index].isWhitespace
    }
}

/// Controls how often active playback becomes durable. Live library updates
/// are separately throttled to a much shorter interval for responsive UI.
enum PlaybackCheckpointPolicy {
    static let persistenceInterval: TimeInterval = 30

    static func shouldPersist(
        isActivelyPlaying: Bool,
        lastCheckpoint: Date?,
        now: Date
    ) -> Bool {
        guard isActivelyPlaying else { return false }
        guard let lastCheckpoint else { return true }
        return now.timeIntervalSince(lastCheckpoint) >= persistenceInterval
    }
}

/// Manages the state for reading a single book
@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var book: Book
    let libraryViewModel: LibraryViewModel
    let settingsViewModel: SettingsViewModel
    var soundEffectService: SoundEffectService?
    #if os(iOS)
    /// The iPhone's hooks into this reader (`ReaderPhoneHooks`), which the
    /// phone's session fills as it makes the reader. The defaults do what the
    /// Mac does.
    var phoneHooks = ReaderPhoneHooks()
    #endif

    @Published var content: DocumentContent? {
        // Derive the published heading list from whatever content the reader
        // holds, so the headings panel and every heading-based location label
        // always count exactly the same headings.
        didSet { headings = content?.allHeadings ?? [] }
    }
    @Published var currentChapterIndex = 0 {
        didSet {
            letGoOfOpenedPlaceAnchorIfLeft()
            schedulePlaybackUIRefresh()
            scheduleLivePositionPublish()
        }
    }
    /// Raw reading cursor used for playback, seeking, and persistence.
    /// UI surfaces observe throttled display mirrors instead of this value
    /// directly so word-level callbacks do not rebuild the reader view on
    /// every spoken word.
    var currentCharacterOffset = 0 {
        didSet {
            letGoOfOpenedPlaceAnchorIfLeft()
            schedulePlaybackUIRefresh()
            scheduleLivePositionPublish()
        }
    }
    /// Throttled mirror of the current chapter index for SwiftUI/VoiceOver.
    @Published private(set) var displayChapterIndex = 0
    /// Throttled mirror of the current character offset for SwiftUI/VoiceOver.
    @Published private(set) var displayCharacterOffset = 0
    /// Cached visible text window for the reader surface.
    @Published private(set) var displayVisibleTextWindow = ""
    @Published var isLoading = true
    /// What the reader shows in place of its book while it gets the book
    /// from the cloud (FR02): a download, or why the book isn't ready. Nil
    /// while it shows the book, or Loading.
    @Published var cloudPhase: ReaderCloudPhase?
    @Published var errorMessage: String?
    /// The audio failure `errorMessage` reports, kept while the message is
    /// shown so its alert can offer Retry. Nil for every other error.
    @Published var audioPlaybackFailure: AudioPlaybackFailure?
    /// What the reader keeps of the speech engine's refusals while its
    /// window is open (B05): the report its sheet shows, and how often each
    /// place was refused. Changed only by ReaderViewModel+SpeechRefusal.
    @Published var speechRefusalAlert = SpeechRefusalAlert()
    /// Every heading in the book, in reading order: the headings panel's rows
    /// and the list that heading numbers count. Kept in step with `content`.
    @Published var headings: [Heading] = []
    /// How many times Go to Page… was asked for in this reader; the status
    /// row opens its page field at each (PG03).
    @Published var goToPageRequests = 0
    @Published var bookmarks: [Bookmark] = []
    /// An EPUB's package metadata with the book's own edits, which the
    /// metadata editor starts from; nil until it is known, and for every
    /// other format (`showEPUBMetadata()`).
    @Published var epubMetadata: EPUBMetadata?
    @Published var audioMetadata: AudioMetadata?
    /// Reads an EPUB's package metadata from its file, off the main thread,
    /// for a book whose row does not keep it (`showEPUBMetadata()`): the
    /// read Book Info makes, which never downloads a file that is only in
    /// the cloud (FR02). Tests replace it before the book loads, to count
    /// the reads or to hold one back.
    var readEPUBMetadata: @Sendable (URL) throws -> EPUBMetadata = LibraryBookInfoReader.system.readEPUBMetadata

    /// Republished from speechService so SwiftUI views update when playback state changes
    @Published var isCurrentlyPlaying = false
    @Published var isCurrentlyPaused = false

    /// True while the "Where Am I?" announcement is speaking
    @Published var isWhereAmISpeaking = false

    /// Current WPM — forwarded from speechService so SwiftUI views update
    @Published var currentWPM: Double = 200

    let speechService = SpeechService()
    /// This reader's own identity, which no other reader shares, not even
    /// one showing the same book: the owner of the sleep timer it sets and of
    /// its Now Playing session, so that a timer, or a media command, belongs
    /// to the window it came from (TODO P01).
    let readerID = UUID()
    /// Shared singleton — there is exactly one sleep timer in the app.
    /// Owner-scoped calls pass `readerID`, so another window's playback, even
    /// of the same book, never affects the timer this reader set.
    let sleepTimerService = SleepTimerService.shared
    /// Where the heading this reader's End of heading sleep timer waits for
    /// ends: the next heading after the cursor as the timer was set, whose
    /// start stops playback (finding #787). Nil when no heading follows, so
    /// that the heading ends with the book, and when this reader set no such
    /// timer; read only while that timer is this reader's and in effect.
    /// Accessed from the Playback extension.
    var sleepTimerNextHeading: Heading?
    /// Every reader window receives a unique media owner, even when two
    /// windows happen to show the same book.
    lazy var nowPlayingService = NowPlayingSession(
        ownerID: readerID,
        diagnosticLabel: "book-\(book.id.uuidString.prefix(8))",
        coordinator: nowPlayingCoordinator
    )
    /// The Now Playing coordinator this reader's media session joins, which
    /// hands it the system's media commands (the AirPods, the media keys):
    /// the app's shared one, unless the reader was created with its own, as
    /// tests do to send it commands as MediaPlayer does.
    let nowPlayingCoordinator: NowPlayingService
    /// Text substitution rules applied to every chapter before it is spoken:
    /// the shared rules edited in Substitutions settings, unless the reader
    /// was created with its own.
    let substitutionService: TextSubstitutionService
    /// Where Continue to Next Book leaves its requests to start playing:
    /// the shared store, unless the reader was created with its own.
    let autoplayRequests: ReaderAutoplayRequests
    /// Where a Library window opening this book from the Reading List, or a
    /// book continuing to it through the reading list, asks this reader to
    /// read it from the list (FR09): the shared store, unless the reader
    /// was created with its own.
    let readingListRequests: ReadingListOpenRequests
    /// Where the Search Library window asks this reader to move to a match
    /// it found in this book (`claimLibrarySearchJump()`): the shared
    /// store, unless the reader was created with its own.
    let libraryJumpRequests: LibrarySearchJumpRequests
    /// How many requests to move to a library search's match this reader
    /// has claimed: a search for a match's new place that runs in the
    /// background moves the cursor only if no later request was claimed
    /// meanwhile (`claimLibrarySearchJump()`).
    var libraryJumpGeneration = 0
    /// The search of the whole book for a match that moved, while one runs
    /// for the latest request claimed; cancelled when a later request is
    /// claimed and when the reader closes (`cancelLibraryJumpSearch()`), so
    /// it never runs on for a request or a reader that is gone.
    var libraryJumpSearch: Task<BookSearchOutcome?, Never>?
    /// Where a reader that switched its window to this book asks this reader
    /// to see to the window's focus once it has found it (0.2.5): the shared
    /// store, unless the reader was created with its own.
    let windowSwitchRequests: WindowSwitchRequests
    /// Whether a move to another book that this reader announced carries a
    /// running sleep timer (`carriesSleepTimerOnAMove`): set as the move is
    /// announced, read as the book is asked for, so a timer that began to fade
    /// out in between ends listening, and the book is not started
    /// (`showNextBook`). Accessed from the NextBookWindow and
    /// SleepTimerHandOver extensions.
    var moveCarriesSleepTimer = false
    /// The hold the move announced last made for its book, while the move has
    /// not asked yet: a cancelling move undoes it, so a cancelled move leaves
    /// no trace (`cancelPendingMoves()`).
    var pendingMoveHold: PendingMoveHold?
    /// The move this reader asked for last, until its book's reader claims
    /// the request to play it: a later move from this reader cancels it
    /// within that span, as the last move wins (`cancelPendingMoves()`).
    var askedMove: AskedMove?
    /// The sleep timer's expiry count as a move that carries a timer was
    /// announced (`SleepTimerService.expiryCount`), nil for a move that carries
    /// none: the ask drops the move if the timer ran out since.
    var moveExpiryMark: Int?
    /// Counts the moves this reader announces, so the half second's pending
    /// ask of an earlier move does nothing once a later one is announced:
    /// Next then Previous asks once (`announceMove`).
    var pendingMoveGeneration = 0
    /// Whether the move announced last, and not yet asked for, was to play
    /// its book: a second move before the ask counts the book as playing,
    /// though the first move paused it.
    var pendingMovePlays = false
    /// The window of a reader a switch made, found before its book has
    /// loaded: its focus is seen to once the book has loaded
    /// (`attach(to:)`, `placeFocusAfterSwitchIfDue()`).
    weak var windowAwaitingFocusAfterLoad: PlatformWindow?
    /// Where this reader's book stands in the reading list while the reader
    /// reads it from the list (FR09): opened from the Reading List, or
    /// reached through the list by a book that continued to it. Nil while it
    /// does not, as for a book opened any other way, even one in the list.
    /// Set only by ReaderViewModel+ReadingList.
    @Published var readingListPlace: ReadingListPlace?
    /// Whether this reader has told the library that it rests on its finished
    /// book, read from the reading list, so a finished book the list is to
    /// drop stays on it until this reader moves on or closes
    /// (`holdFinishedBookOnReadingList()`). Set only by
    /// ReaderViewModel+ReadingList.
    var holdsFinishedBookOnReadingList = false
    /// The center this reader listens on for commands and for Continue to
    /// Next Book, and posts its own Continue to Next Book to: the default
    /// center, unless the reader was created with its own, as tests do to
    /// keep their notifications from the running app.
    let notificationCenter: NotificationCenter
    /// Renders the look-ahead's audio: the shared render queue, unless the
    /// reader was created with its own, as tests do to hold renders.
    let renderScheduler: any SpeechRenderScheduling
    /// The cloud services the reader gets its book ready with when the
    /// library is in a cloud location (FR02): the app's, unless the reader
    /// was created with its own, as tests do.
    let cloudServices: ReaderCloudServices
    /// The queue each load reads the book's files on, off the main thread
    /// (`loadContent()`, `loadDownloadedBook()`): a global queue, unless the
    /// reader was created with its own, as tests do to hold a load's read
    /// until the moment they choose, such as the middle of a move of the
    /// book's package.
    let loadQueue: DispatchQueue
    /// The reader's cloud work: its download, its working copy, and where
    /// the library was found to be (FR02).
    var cloudSession = ReaderCloudSession()
    let readingStatsService = ReadingStatsService.shared
    let audioPlaybackService = AudioPlaybackService()

    /// Whether this book is an audio book (uses audio playback instead of TTS)
    var isAudioBook: Bool { book.format.isAudio }

    /// For multi-file audio books (ZIP import): file paths for each chapter
    var audioChapterFiles: [String] = []

    /// For segmented audio (DAISY): the clips each chapter plays. When
    /// non-empty, chapter i plays `audioSegments[i].clips` one after
    /// another, each a time range within a file of the book's audio
    /// folder, as one chain (see `audioClipChain(forChapterAt:)`).
    var audioSegments: [AudioSegment] = []

    /// The silence the reader keeps after each chapter before it starts the
    /// next, while the book plays on from one chapter into the next
    /// (`ChapterPauses`): for now, the pauses a multi-file audiobook's
    /// manifest puts between its tracks; none for every other book, which
    /// plays straight on as it always has. Set as the book loads, from the
    /// manifest, never from the saved index (`LoadedContent.chapterPauses`).
    /// Accessed from the Playback extension.
    var chapterPauses = ChapterPauses.none

    /// The start of the cursor's chapter, waiting out the pause after the
    /// chapter that played to its end (`chapterPauses`); nil the rest of
    /// the time. Playback is under way while it waits
    /// (`isPlaybackUnderWay`), and whatever pauses or stops the book, closes
    /// the reader, or starts playback cancels it
    /// (`stopWaitingOutChapterPause(because:)`). Accessed from the Playback
    /// and LibraryUpdates extensions.
    var chapterStartAfterPause: DispatchWorkItem?

    /// Audio playback multiplier, separate from WPM. Always a value returned
    /// by `AudioSpeed.normalized(_:)`; change it through `setAudioSpeed(_:)`.
    @Published var audioSpeed: Double = AudioSpeed.normal

    /// Current text transformation for mapping modified<->original offsets.
    /// Accessed from Playback extension when speaking chapters.
    var currentTransformation: TextTransformation?

    /// Composed offset map covering the full text pipeline (filter → pause → substitution).
    /// Used to convert between original-text offsets and modified-text offsets for seeking.
    var currentOffsetMap: ComposedOffsetMap?

    /// Saved position before heading/bookmark navigation (for "go back to where I was").
    /// Accessed from Bookmarks extension.
    @Published var hasSavedPosition = false
    var savedChapterIndex: Int = 0
    var savedCharacterOffset: Int = 0

    /// The NSWindow hosting this reader. Used to check if this is the focused window
    /// before responding to keyboard shortcut notifications (prevents K from activating
    /// playback in ALL open book windows at once).
    weak var hostWindow: PlatformWindow?

    /// Separate synthesizer for "Where Am I?" announcements (not the book reader).
    /// Replaced with a fresh one when the system cancels an announcement on
    /// its own (`replaceWhereAmISynthesizer()`): after the speech engine
    /// refuses an utterance, the synthesizer that held it never speaks again.
    /// Accessed from WhereAmI and Playback extensions.
    var whereAmISynth = AVSpeechSynthesizer()
    /// The announcement the Where Am I synthesizer speaks now, so that its
    /// end and its cancel are told apart from those of one the reader
    /// stopped or replaced (`stopWhereAmISynthesizer()`); nil while none
    /// speaks. Held strongly, as the speech service holds its live
    /// utterance, so that its identity stays its own until the synthesizer's
    /// callbacks are compared on the main queue. Accessed from the WhereAmI
    /// extension.
    var liveWhereAmIUtterance: AVSpeechUtterance?
    /// Takes the utterance a Where Am I announcement would hand its
    /// synthesizer, in its place, so hosted tests can deliver the
    /// synthesizer's callbacks for it without a sound. Nil, as in the app,
    /// hands it to the synthesizer.
    var _whereAmIUtteranceRecorderForTesting: ((AVSpeechUtterance) -> Void)?
    /// Whether playback was active before "Where Am I?" interrupted it.
    /// Accessed from WhereAmI and Playback extensions.
    var wasPlayingBeforeWhereAmI = false
    /// Whether the book a Where Am I announcement paused resumes once the
    /// end sound of that announcement, which ended by itself, has played
    /// (`whereAmIEndSoundDelay`): set as it ends, and cleared as the book
    /// resumes, or by whatever settles the book first: a pause, a stop,
    /// Play/Pause, a command that interrupts Where Am I, or another
    /// announcement, which takes the resume over (REV11). Accessed from the
    /// WhereAmI and Playback extensions.
    var isWhereAmIResumePending = false
    /// Whether the end sound of a Where Am I announcement that ended by
    /// itself is still playing: the window between the announcement's end
    /// (`whereAmIAnnouncementFinished()`) and the work it schedules for once
    /// the sound has played (`resumeAfterWhereAmIEndSound()`,
    /// `whereAmIEndSoundDelay` later). Set as the announcement ends, and
    /// cleared first thing by that work; nothing else sets or clears it, and
    /// an announcement the system cancels, which plays no end sound, leaves
    /// it false.
    ///
    /// It needs a flag of its own: in the window `isWhereAmISpeaking` is
    /// already false, and `isWhereAmIResumePending` is set only for a book
    /// that was playing before the announcement, so a reader waiting for a
    /// chapter's download when Where Am I? was pressed has neither. Without
    /// it, a chapter's download or a package's move that ended in the window
    /// started audio over the end sound (`isWhereAmISpeakingOrSoundingItsEnd`).
    /// Accessed from the WhereAmI extension.
    var isWhereAmIEndSoundPlaying = false
    /// Whether a Play pressed while a Where Am I announcement spoke waits
    /// for the announcement to end to start the book
    /// (`startPlayHeldByWhereAmI()`): for a book the announcement had not
    /// paused (one paused or stopped before it), or for the one it paused,
    /// should the system cancel the announcement rather than let it resume
    /// the book (`holdPlayForWhereAmI()`). Set by the Play, and cleared as
    /// the book starts or resumes, as the announcement ends by itself, is
    /// pressed away, or is cancelled by the system, or by a pause, a stop,
    /// or Play/Pause, which leave the book as it was (REV11). Accessed from
    /// the WhereAmI and Playback extensions.
    var isPlayHeldByWhereAmI = false
    /// Whether the chapter about to play, whose files finished downloading
    /// while a Where Am I announcement spoke (FR02), or whose package's move
    /// ended while one spoke with its audio set aside for the move, waits
    /// for the announcement to end to play (`startPlayHeldByWhereAmI()`),
    /// the reader showing Playing meanwhile, as a Play pressed during it
    /// waits: set by the download's or the move's end
    /// (`resumeAudioAfterPackageMove()`), and cleared as the chapter starts
    /// (`playAudioChapter()`), or by a pause, Play/Pause, or a stop, which
    /// leave it unplayed (`stopWaitingForChapterDownload(because:)`,
    /// `endWhereAmIAsTheBookStops()`). Accessed from the CloudDownload,
    /// LibraryUpdates, WhereAmI, and Playback extensions.
    var isChapterHeldByWhereAmI = false
    /// Takes the work a Where Am I announcement that ended by itself leaves
    /// for once its end sound has played, in place of the main queue's
    /// delay (`whereAmIEndSoundDelay`), so that hosted tests run it when
    /// they choose rather than wait for it. Nil, as in the app, runs it on
    /// the main queue after the delay.
    var _afterWhereAmIEndSoundForTesting: ((@escaping @MainActor @Sendable () -> Void) -> Void)?
    /// Set when playback was paused because the system audio route changed
    /// (for example AirPods disconnecting). The next resume must recreate
    /// the active playback backend so audio binds to the newly-current
    /// output device instead of continuing a graph/synth paused on the old
    /// route. Also set when the library moves a paused audiobook's files, so
    /// resuming plays them from where they are then instead of from a player
    /// still holding the old place (TODO P10). Play's resume and a Where Am
    /// I? announcement's resume of the book it paused both honor it
    /// (`restartPlaybackAtCursor()`), which clears it.
    var restartPlaybackBackendOnNextResume = false
    /// Whether the book has finished and rests at its end: its last chapter
    /// played or was spoken to its end, or nothing speakable was left, and
    /// its end-of-book behavior ended listening there, with nothing playing
    /// or paused (`handleEndOfBook()`). A finished book keeps its media
    /// session, shown paused at its end, so that the AirPods and the media
    /// keys still reach this reader, and its next backward skip plays the
    /// book again from where the skip lands (`performSkip(unit:forward:)`);
    /// Release Media Controls is offered meanwhile, while the book holds
    /// the controls (`canReleaseMediaControls`).
    /// Set too as a book saved exactly at its end opens (`showLoadedContent`,
    /// TODO P07), so a finished book stays finished after TextMouth quits.
    /// Cleared when playback starts (`play()`), when a jump moves the cursor
    /// away from the end (`navigateTo(chapterIndex:characterOffset:)`), when
    /// a backward skip moves it while another book plays
    /// (`performSkip(unit:forward:)`), when playback is stopped (`stop()`),
    /// and when the book hands listening over to the next book, in its
    /// folder or in the reading list, which takes the media controls
    /// (`handOverToNextBook(to:titled:askingWith:)`).
    /// A book that loops back to its beginning is not finished: it plays
    /// again, or waits at its start. Accessed from the Playback and
    /// Navigation extensions.
    var hasFinishedBook = false
    /// Whether this reader has already looked for a feed's next episode to
    /// download before this one ends (FR19, task C): the search runs once
    /// when the time left first falls within `predownloadLeadTime`, whatever
    /// it finds, not every second. Accessed from the Predownload extension.
    var hasAskedForPredownload = false
    /// How much of the episode must be left for the next one to be
    /// downloaded (FR19, task C). Production never changes it; a test lowers
    /// it to show that more time left asks for nothing.
    var predownloadLeadTime: TimeInterval = ListeningOptions.predownloadLeadTime
    /// The wait for the next episode's download (FR19, task B3): while this
    /// finished episode's feed downloads the episode that follows it, the
    /// subscription to the feed engine's events that hands listening over
    /// when it arrives, or says why playback stopped when it fails. Nil
    /// when no wait is under way; a new wait replaces an earlier one, and
    /// closing the reader ends it. Held here because an extension cannot
    /// hold a stored property; used by `ReaderViewModel+EpisodeDownload`.
    var nextEpisodeWait: AnyCancellable? {
        didSet {
            if nextEpisodeWait == nil { episodeWaitPlays = false }
        }
    }
    /// Whether the wait for a next episode under way is to play the episode
    /// when it arrives: a later move that ends the wait counts the book as
    /// playing then (`beginMoveToAnotherBook()`). False with no wait.
    var episodeWaitPlays = false
    /// Whether the play under way replays a finished book's end, as a
    /// backward skip after the end starts it (`performSkip(unit:forward:)`):
    /// the end it plays on to is no new finish (TODO P07; the user,
    /// October 10, 2026, question 14: yes), so `handleEndOfBook()` neither
    /// counts it nor tells it (`.bookDidFinish`), and does all else the end
    /// does. Set by that skip; cleared by the end it reaches, by a jump
    /// (`navigateTo(chapterIndex:characterOffset:)`), and by a stop.
    /// Accessed from the Playback and Navigation extensions.
    var replaysFinishedEnd = false
    /// The latest hand-over of listening from this finished book to the
    /// next one, in its folder or in the reading list
    /// (`handOverToNextBook(to:titled:askingWith:)`). While it is under way,
    /// from "Starting: <title>" until the next book's reader claims the
    /// request to play it, a Play that reaches this reader starts the next
    /// book instead of playing this one (`NextBookHandOver`). Nil until a
    /// book hands over, and again once a Play finds the hand-over done.
    /// Accessed from the Playback extension.
    var nextBookHandOver: NextBookHandOver?
    /// Shows the book with the given ID in this reader's own window, in
    /// place of this reader's book: the reader window's scene sets the
    /// window's book (`BookReaderWindowView`). Nil for a reader that cannot
    /// switch its window, as in a test, which then opens a new window as
    /// before 0.2.5. Accessed from the NextBookWindow extension.
    var nextBookWindowSwitcher: ((UUID) -> Void)?
    /// Whether this reader's window now shows another book: set just
    /// before the switch, so the closing view leaves the window registered
    /// (the new view registers the same window) and closes this reader.
    /// Accessed from the NextBookWindow extension and the window's view.
    var hasSwitchedWindow = false
    /// What this reader's window is doing, as far as a switch is concerned;
    /// nil reads it from `hostWindow` and the app. A test that has no
    /// window sets it (`windowStanding`).
    var windowStandingOverride: NextBookWindowStanding?
    /// Places keyboard and VoiceOver focus in the window of a reader that a
    /// switch made, once its window is found (`attach(to:)`); a test
    /// replaces it with a recorder.
    var placeFocusAfterSwitch: (PlatformWindow) -> Void = { SwitchedWindowFocus.place(in: $0) }
    /// The revision of the latest library update this reader has applied to
    /// its copy of the book (see `LibraryBookUpdates`); an update that is
    /// not newer is ignored. Written only by `applyLibraryUpdate(_:)` and
    /// when the reader starts watching its book.
    var appliedLibraryRevision = 0
    /// Audio that was playing when the library said the book's package was
    /// about to move, set aside until the move ends and playback goes on
    /// from the cursor (TODO P10); nil the rest of the time. Meanwhile the
    /// book counts as playing (`isPlaybackUnderWay`), and a pause or a stop
    /// lets the audio go (`letGoOfAudioSetAsideForMove(because:)`), so that
    /// the move's end leaves the book as the listener left it.
    var audioPausedForMove: AudioPausedForMove?
    /// Whether the book loads once the move of its package under way is
    /// over (`isPackageMoving`): a load was asked for while the package
    /// moved, and has read nothing yet (`beginReadingForLoad()`), or a
    /// load's read of the book's files failed meanwhile, its files perhaps
    /// gone from under it. The move's end loads the book from the start,
    /// from wherever it is then (`loadAfterPackageMove()`, TODO P10).
    /// Accessed from the LibraryUpdates extension.
    var loadWaitsForPackageMove = false
    /// Whether a move of the book's package began while the book loaded, so
    /// that a failure of the read under way may be the move's doing, its
    /// files gone from where the read began even when the move was put
    /// back: the book is then loaded again rather than said to be
    /// unreadable (`loadAgainAfterMove(ofFilesReadAt:)`, TODO P10). Set as
    /// the library says the package will move, and cleared as each read of
    /// the book's files begins (`beginReadingForLoad()`). Accessed from the
    /// LibraryUpdates extension.
    var loadMetPackageMove = false
    /// Whether a load waits for the book's text to be read again in another
    /// encoding (`beginReadingForLoad()`, encodingchoice), so a load asked
    /// for again meanwhile adds no second wait. Accessed from the
    /// LibraryUpdates extension.
    var loadWaitsForReread = false
    /// The book's edited text, with the moves of its places the edit took,
    /// when the user's edit was taken while this reader was still loading
    /// the text it had (FR05): shown once loading ends
    /// (`showEditedTextWaitingForLoad()`); nil the rest of the time.
    var editedTextWaitingForLoad: EditedTextWaitingForLoad?
    /// An audiobook's transcript text when it changed while this reader was
    /// still loading (FR05): shown once loading ends
    /// (`showTranscriptWaitingForLoad()`); nil the rest of the time.
    var transcriptWaitingForLoad: TranscriptTextChange?
    /// An edit of an audiobook's manifest taken while this reader was still
    /// loading (FR17): shown once loading ends
    /// (`showManifestEditWaitingForLoad()`); nil the rest of the time.
    var manifestEditWaitingForLoad: BookManifestEdit?
    /// The manifest editor that acts on what this reader's looks at its
    /// audiobook's manifest find (FR18): the app's, unless a test gives
    /// its own.
    lazy var manifestEditor: BookManifestEditor = .shared
    /// Whether this reader's last load stopped because the book's content.md
    /// held an edit TextMouth could not take (`BookTextEditPending`, FR05),
    /// so the reader opens the book with the edit taken next
    /// (`showEditedText(_:)`).
    var loadHeldByTextEdit = false
    /// Why this audiobook, though it has a transcript, shows none of its
    /// text now (FR05): its transcript or text is only in iCloud, its audio
    /// changed since it was transcribed, or its edited text is held until the
    /// user settles it in their editor. Search in Book says it in place of
    /// opening (`announceNoTextToSearch(hasTranscript:)`). Set as the book
    /// loads; cleared once text arrives or the transcript is deleted
    /// (`showTranscript(_:)`). Nil while text is shown, for a book without a
    /// transcript, and when the reason is none of these.
    var transcriptWithheld: TranscriptTextWithheld?
    /// True after the user explicitly releases Now Playing / headphone media
    /// controls for this open reader. Starting playback in TextMouth clears it.
    @Published var mediaControlsReleased = false
    /// The summary the Where Am I announcement speaking says, brief or full
    /// (FR12): set as each announcement starts, and read only while one
    /// speaks (`isWhereAmISpeaking`). Accessed from the WhereAmI extension.
    var whereAmIDetail: SummaryDetail = .brief
    /// Text of the most recent VoiceOver announcement, recorded even when no
    /// window can post it, so regression tests can verify spoken wording.
    /// Written only by `announceToVoiceOver(_:)`.
    var lastAnnouncement: String?
    /// What to say once the Search in Book sheet has closed after a result of
    /// a transcript was chosen: where the reader moved to. Held back so it is
    /// heard when VoiceOver has settled on the reader, not over the sheet's
    /// closing. Set by `navigateToTranscriptSearchResult`, spoken and cleared
    /// by `announcePendingJump()`.
    var pendingJumpAnnouncement: String?

    /// Base offset for word-spoken callback tracking
    var utteranceBaseOffset: Int = 0
    private var cancellables = Set<AnyCancellable>()
    /// Coalesces rapid playback cursor changes into a single UI refresh.
    private var playbackUIRefreshWorkItem: DispatchWorkItem?
    /// Coalesces word-level cursor changes before publishing to library rows.
    private var livePositionWorkItem: DispatchWorkItem?
    private var lastLivePositionPublish = Date.distantPast
    private var lastPersistedCheckpoint: Date?
    /// The chapter and offset of the last durable save of the place
    /// (`savePosition()` or a checkpoint), nil before the first: what
    /// `savePositionIfMoved()` compares the cursor with, so a quit writes
    /// only the places that changed.
    private var lastSavedPlace: TextPlace?
    /// Whether the cursor was published live (playback moving it) since the
    /// last durable save. It counts as a move even should the cursor have
    /// come back to the saved place.
    private var hasPlayedSinceSave = false
    /// The measure of the text this reader shows, which every anchor it
    /// captures records (T06; `noteLoadedTextForAnchors(cacheFormatVersion:)`):
    /// nil before the text loads, or when the version of the content.md it
    /// came from is not known.
    var textAnchorMeasure: String?
    /// The place the book opened at, with the anchor it was saved with,
    /// while the cursor has not left it (T06): saved again there, the place
    /// keeps the words it was saved with (`anchorToSave(at:)`). Nil once the
    /// cursor moves, for an audiobook, and for a place saved without words.
    var openedPlaceAnchor: OpenedPlaceAnchor?
    private struct PlaybackUIRefreshSnapshot {
        let chapterIndex: Int
        let offset: Int
    }
    private struct VisibleTextWindowState {
        let chapterIndex: Int
        let startOffset: Int
        let endOffset: Int
    }
    private struct VisibleTextWindow {
        let text: String
        let startOffset: Int
        let endOffset: Int
    }
    private var pendingPlaybackUIRefresh: PlaybackUIRefreshSnapshot?
    private var visibleTextWindowState: VisibleTextWindowState?
    /// Debounce skip calls — ignore rapid-fire duplicates.
    /// Accessed from Navigation extension.
    var lastSkipTime: Date = .distantPast
    /// The next speakable chapter, rendered ahead so it can start the moment
    /// the current chapter ends; nil when nothing is looked ahead to.
    /// Accessed from Navigation and Playback extensions.
    var lookAhead: LookAhead?
    /// The speech prepared for recent chapters, and the look-ahead's, each
    /// used again while everything it was prepared from stays the same
    /// (PERF02). Accessed from the Playback extension.
    var chapterSpeechCache = ChapterSpeechCache()
    /// The playback generation. Every chapter play (see `ChapterPlay`), and
    /// every move to another chapter or loop, begins a new one. The end the
    /// speech or audio service reports for a play ends it only while the
    /// play's generation is still this one, so the end of a chapter the
    /// reader has left is ignored; look-ahead renders are kept only within
    /// the generation they began in.
    /// Accessed from Navigation and Playback extensions.
    var chapterPlaybackGeneration: Int = 0

    /// Prevent Where Am I delegate from being deallocated.
    /// Accessed from WhereAmI extension.
    var whereAmIDelegate: WhereAmIDelegateHelper?
    private(set) var hasClosed = false

    /// For audio books, 10 characters = 1 second of audio.
    /// All time calculations use this constant to convert character offsets to/from seconds.
    nonisolated static let audioCharsPerSecond: Double = 10.0
    /// How often playback-driven UI mirrors should refresh while speech is active.
    static let playbackUIRefreshInterval: TimeInterval = 0.12
    /// Library rows need to feel current without rebuilding on every word.
    static let livePositionPublishInterval: TimeInterval = 1
    /// How much of the current visible text window should remain as a guard band
    /// before the reader surface is rebuilt around a new center point.
    static let visibleTextWindowGuardFraction = 0.25

    /// Minimum gap between successive skip operations. Shared by
    /// `skipForward` and `skipBackward`. Wider than the previous 0.3s
    /// to defend against media-key + keyboard double-fire that the
    /// older window left vulnerable to a brief macOS scheduling hiccup.
    nonisolated static let skipDebounceWindow: TimeInterval = 0.4

    /// Open a reader for `book` and start loading its content.
    ///
    /// - Parameters:
    ///   - book: The book to read; the reader keeps its own copy.
    ///   - libraryViewModel: The library that persists this book's state.
    ///   - settingsViewModel: The global settings playback follows.
    ///   - substitutionService: Rules applied to text before it is spoken.
    ///     Nil uses the shared rules edited in Substitutions settings; tests
    ///     pass their own so the user's rules cannot change what is spoken.
    ///   - autoplayRequests: Where finished books ask this one to start
    ///     playing. Nil uses the shared store; tests pass their own.
    ///   - readingListRequests: Where this book is asked to be read from
    ///     the reading list (FR09). Nil uses the shared store; tests pass
    ///     their own.
    ///   - libraryJumpRequests: Where the Search Library window asks this
    ///     reader to move to a match. Nil uses the shared store; tests pass
    ///     their own.
    ///   - notificationCenter: Where the reader listens for commands and for
    ///     Continue to Next Book, and posts its own Continue to Next Book.
    ///     Tests pass their own, so their notifications never reach the
    ///     running app's windows.
    ///   - renderScheduler: Renders the next chapter ahead of time. Nil uses
    ///     the shared render queue; tests pass one that holds each render
    ///     until they let it start and finish.
    ///   - cloud: The cloud services that get a book in a cloud library ready
    ///     to read (FR02). Nil uses the app's; tests pass fakes.
    ///   - nowPlaying: The Now Playing coordinator the reader's media session
    ///     joins. Nil uses the app's shared one; tests pass their own, made
    ///     without system integrations, to send it the system's commands.
    ///   - loadQueue: The queue each load reads the book's files on. Nil uses
    ///     a global queue; tests pass a queue of their own that holds the
    ///     reads until they let them begin.
    init(
        book: Book,
        libraryViewModel: LibraryViewModel,
        settingsViewModel: SettingsViewModel,
        substitutionService: TextSubstitutionService? = nil,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        readingListRequests: ReadingListOpenRequests? = nil,
        libraryJumpRequests: LibrarySearchJumpRequests? = nil,
        windowSwitchRequests: WindowSwitchRequests? = nil,
        notificationCenter: NotificationCenter = .default,
        renderScheduler: (any SpeechRenderScheduling)? = nil,
        cloud: ReaderCloudServices? = nil,
        nowPlaying: NowPlayingService? = nil,
        loadQueue: DispatchQueue? = nil
    ) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self.settingsViewModel = settingsViewModel
        // Resolved here rather than as default arguments, so the shared
        // main-actor services are read inside this main-actor initializer.
        self.substitutionService = substitutionService ?? .shared
        self.autoplayRequests = autoplayRequests ?? .shared
        self.readingListRequests = readingListRequests ?? .shared
        self.windowSwitchRequests = windowSwitchRequests ?? .shared
        self.notificationCenter = notificationCenter
        self.renderScheduler = renderScheduler ?? SpeechRenderCoordinator.shared
        self.cloudServices = cloud ?? .app
        self.nowPlayingCoordinator = nowPlaying ?? .shared
        self.loadQueue = loadQueue ?? .global(qos: .userInitiated)
        self.libraryJumpRequests = libraryJumpRequests ?? .shared
        self.bookmarks = book.bookmarks

        // A timer held for this book is this reader's to take, or to release
        // on every way it can fail, for as long as it is open: the library's
        // registry says so (`bookIsOpenCheck`).
        libraryViewModel.registerOpenBook(book.id)

        // Restore reading position
        if let pos = book.readingPosition {
            currentChapterIndex = pos.chapterIndex
            currentCharacterOffset = pos.characterOffset
        }

        // Apply per-book voice/speed/pitch overrides (never an audio multiplier)
        applyLocalSpeechOverrides()

        setupCallbacks()
        setupNotifications()
        observeSpokenAudioSettings()
        observeLibraryUpdates()
        observeReadingList()
        observeLibrarySearchJumps()
        observeSleepTimerHandOvers()
        forwardSpeechState()
        // TextMouth's memory is watched while this reader plays (B07).
        followPlaybackForMemoryGuard().store(in: &cancellables)

        if isAudioBook {
            setupAudioCallbacks()
            // Audio books keep their multiplier in `localWPM`. Restore it
            // clamped and snapped, exactly as the player and estimates use it.
            if let localSpeed = book.localWPM {
                audioSpeed = AudioSpeed.normalized(localSpeed)
            }
        }

        loadContent()
    }

    /// Bring the look-ahead up to date when a setting that shapes spoken audio
    /// changes outside this reader: the substitution rules or whether they
    /// apply, edited in Settings, and the global punctuation pause level,
    /// which Settings or an edit to config.json can change. A change notice
    /// can arrive before its change is in place (the substitution service's
    /// arrives before it), so the refresh waits for the main queue's next
    /// turn, by which time it is.
    private func observeSpokenAudioSettings() {
        substitutionService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLookAhead() }
            .store(in: &cancellables)

        // The settings model announces every change it makes, once or more;
        // only a new punctuation pause level shapes spoken audio.
        settingsViewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [weak self] _ in self?.settingsViewModel.punctuationPauseLevel }
            .prepend(settingsViewModel.punctuationPauseLevel)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshLookAhead() }
            .store(in: &cancellables)
    }

    /// Keep this reader's copy of its book current while the library edits,
    /// renames, or moves the book from another window (TODO P10). The reader
    /// watches its book until it closes, and applies every update newer than
    /// the book's revision when it opened (see `ReaderViewModel+LibraryUpdates`).
    /// Events arrive synchronously on the main actor, while the library is
    /// making the change.
    private func observeLibraryUpdates() {
        let updates = libraryViewModel.bookUpdates
        appliedLibraryRevision = updates.revision(of: book.id)
        updates.watch(book)
        updates.events(for: book.id)
            .sink { [weak self] event in self?.handleLibraryEvent(event) }
            .store(in: &cancellables)
    }

    /// Listens for the Search Library window asking this reader to move to a
    /// match while it is open already, as the book's window comes forward
    /// for it, and claims the request at once (`claimLibrarySearchJump()`);
    /// one made before this reader existed is claimed as its load ends.
    /// Requests for other books are left for their own readers.
    private func observeLibrarySearchJumps() {
        let bookID = book.id
        libraryJumpRequests.requestsMade
            .filter { $0 == bookID }
            .sink { [weak self] _ in self?.claimLibrarySearchJump() }
            .store(in: &cancellables)
    }

    /// Read this book from the reading list when asked to (FR09). A request
    /// made before this reader existed, as a Library window opened the book
    /// from the Reading List or a book continued to it through the list, is
    /// claimed now, as the open made this reader; one made while the reader
    /// is open, as such an open brings its window forward, is claimed as it
    /// is made (`ReadingListOpenRequests.requestsMade`). Requests for other
    /// books are left for their own readers. While the book is read from the
    /// list, its place follows every change the library makes to the list,
    /// and the book is no longer read from it once it leaves the list
    /// (`followReadingList(in:)`).
    private func observeReadingList() {
        let bookID = book.id
        readingListRequests.requestsMade
            .filter { $0 == bookID }
            .sink { [weak self] _ in self?.claimReadingListRequest() }
            .store(in: &cancellables)
        // Published as each change is made, with the library as it will be.
        libraryViewModel.$library
            .sink { [weak self] library in self?.followReadingList(in: library) }
            .store(in: &cancellables)
        claimReadingListRequest()
    }

    /// Listens for a sleep timer, from any window, being asked for this book
    /// while this reader is open already, as the book's window comes forward
    /// for it, and takes it at once (`claimSleepTimerHandOver()`); one asked
    /// for before this reader existed is taken as its load ends.
    private func observeSleepTimerHandOvers() {
        let bookID = book.id
        sleepTimerService.registry.asksMade
            .filter { $0 == bookID }
            .sink { [weak self] _ in self?.claimSleepTimerHandOver() }
            .store(in: &cancellables)
    }

    /// Forward speechService @Published state to our own @Published properties
    /// so SwiftUI views that observe this ViewModel get updated.
    private func forwardSpeechState() {
        // A reader waiting for its chapter's speech shows Playing whatever
        // the idle speech service says meanwhile, as when a move stops it
        // (`isWaitingForChapterSpeech`).
        speechService.$isSpeaking
            .receive(on: DispatchQueue.main)
            .map { [weak self] isSpeaking in isSpeaking || self?.isWaitingForChapterSpeech == true }
            .assign(to: &$isCurrentlyPlaying)
        speechService.$isPaused
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCurrentlyPaused)
        speechService.$wordsPerMinute
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentWPM)

        $isCurrentlyPlaying
            .combineLatest($isCurrentlyPaused)
            .dropFirst()
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshPlaybackUI(forceVisibleTextRefresh: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - Time & Progress Calculations

    var totalWordCount: Int {
        content?.totalWordCount ?? 0
    }

    var totalEstimatedTime: TimeInterval {
        if isAudioBook {
            return baseAudioDuration / audioSpeed
        }
        return content?.estimatedReadingTime(wpm: speechService.wordsPerMinute) ?? 0
    }

    /// Prefer the analyzed media duration used by library rows. Character
    /// placeholders remain a fallback for legacy audio packages.
    private var baseAudioDuration: TimeInterval {
        if let duration = book.audioDuration, duration > 0 {
            return duration
        }
        if let indexedDuration = content?.contentIndex.totalAudioDuration,
           indexedDuration > 0 {
            return indexedDuration
        }
        return Double(content?.totalCharacterCount ?? 0) / Self.audioCharsPerSecond
    }

    var formattedTotalTime: String {
        TimeFormatting.format(totalEstimatedTime)
    }

    var currentGlobalOffset: Int {
        content?.globalOffset(chapterIndex: currentChapterIndex, localOffset: currentCharacterOffset) ?? 0
    }

    var percentComplete: Double {
        content?.percentComplete(globalOffset: currentGlobalOffset) ?? 0
    }

    var timeRemaining: TimeInterval {
        ReadingTimeEstimator.remaining(
            totalDuration: totalEstimatedTime,
            globalOffset: currentGlobalOffset,
            totalCharacterCount: content?.totalCharacterCount ?? 0
        )
    }

    var formattedTimeRemaining: String {
        TimeFormatting.format(timeRemaining)
    }

    var formattedPercentComplete: String {
        String(format: "%.1f%%", percentComplete)
    }

    /// Time estimate for a specific heading (time from heading start to next heading or end of doc)
    func timeEstimateForHeading(_ heading: Heading) -> TimeInterval {
        guard let content = content else { return 0 }
        let allHeadings = content.allHeadings
        let headingGlobalOffset = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)

        // Find the next heading's global offset
        var nextOffset = content.totalCharacterCount
        if let idx = allHeadings.firstIndex(where: { $0.id == heading.id }),
           idx + 1 < allHeadings.count {
            let next = allHeadings[idx + 1]
            nextOffset = content.globalOffset(chapterIndex: next.chapterIndex, localOffset: next.characterOffset)
        }

        let charCount = nextOffset - headingGlobalOffset

        if isAudioBook {
            guard content.totalCharacterCount > 0 else { return 0 }
            return totalEstimatedTime
                * Double(charCount)
                / Double(content.totalCharacterCount)
        }

        guard content.totalCharacterCount > 0, speechService.wordsPerMinute > 0 else { return 0 }
        let wordEstimate = Double(charCount) / Double(content.totalCharacterCount) * Double(content.totalWordCount)
        return wordEstimate / speechService.wordsPerMinute * 60.0
    }

    /// Percentage through book where a heading starts
    func percentAtHeading(_ heading: Heading) -> Double {
        guard let content = content else { return 0 }
        let globalOffset = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        return content.percentComplete(globalOffset: globalOffset)
    }

    // MARK: - Setup

    private func setupCallbacks() {
        speechService.onWordSpoken = { [weak self] range, _ in
            guard let self = self else { return }
            // Map from modified-text (speech service) offset back to original-text offset
            // using the full composed offset map that tracks all transformation stages
            // (filtering, punctuation pauses, substitutions).
            if let map = self.currentOffsetMap, map.hasChanges {
                self.currentCharacterOffset = map.toOriginal(range.location)
            } else {
                self.currentCharacterOffset = range.location
            }
        }

        // Each chapter's speech, once it starts, reports its end for its own
        // play (see `startSpeaking(_:playing:)`); until one starts, the end
        // belongs to the cursor's chapter.
        listenForSpeechEnd(of: cursorChapterPlay)

        // Speech the Mac's speech engine refused, on a fresh synthesizer
        // too, has stopped at the cursor; the reader makes that stop its
        // own, as a pause would be (#1308), and keeps the report of what
        // was refused for its window (B05).
        speechService.onSpeechRefused = { [weak self] refusal in
            self?.showPlaybackStoppedAfterRefusal(refusal)
        }
        // Speech that paused itself because the voice would not start a
        // passage, on fresh synthesizers too, is made the reader's own pause,
        // and the listener is told once.
        speechService.onSpeechStalled = { [weak self] in
            self?.showPlaybackPausedAfterStartStalls()
        }

        // Sleep timer callbacks are no longer set here — they're passed
        // when this VM starts a timer (see startSleepTimer below). This
        // ensures the active callbacks always belong to whichever book
        // most recently started a timer, since the service is shared.

        nowPlayingService.setup(
            onPlay: { [weak self] in self?.playOrResume() },
            onPause: { [weak self] in self?.pause() },
            onAudioRouteInvalidated: {
                [weak self] in self?.invalidatePlaybackBackendForAudioRouteChange()
            },
            onAudioRouteChangePause: { [weak self] in self?.pauseForAudioRouteChange() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSkipForward: { [weak self] in
                #if os(iOS)
                // The iPhone's moves take one path of their own, which says
                // what a move says on a phone (`ReaderPhoneHooks`).
                if let move = self?.phoneHooks.moveForward {
                    move()
                    return
                }
                #endif
                self?.skipForward()
            },
            onSkipBackward: { [weak self] in
                #if os(iOS)
                if let move = self?.phoneHooks.moveBackward {
                    move()
                    return
                }
                #endif
                self?.skipBackward()
            },
            // NowPlayingService needs to know whether playback is currently
            // running so it can correctly handle the Bluetooth-disconnect
            // suppress window: during that window, a spurious toggle command
            // is converted into a pause if playing, or ignored if already
            // paused (blocking macOS's spurious auto-resume bug).
            //
            // A book Where Am I? will play counts as playing
            // (`whereAmIWillPlayBook`): one the announcement paused, which it
            // plays again as it ends, or after its end sound once it has
            // ended by itself. So the AirPods leaving pause it, which ends
            // the announcement, or its resume still to come, and leaves the
            // book paused, and so do a recording starting
            // (`pauseEveryPlayingReader()`) and another book starting; with
            // the book counted as paused, nothing was paused, and the book
            // played on through the Mac's speakers once the announcement
            // ended.
            //
            // So does a play under way that has not begun to sound
            // (`isPlaybackUnderWay`): one waiting for its chapter's speech,
            // prepared off the main thread, or an audiobook's waiting for its
            // chapter's files to download, or set aside while the library
            // moves its package, each of which shows Playing. Counted as
            // not playing, it was not paused by the AirPods leaving or a
            // recording starting, nor by another book starting unless it was
            // the book last playing, and it began to speak or play once
            // ready, through the Mac's speakers or under the recording
            // (REV12's leftovers, REV13).
            isCurrentlyPlaying: { [weak self] in
                guard let self else { return false }
                return self.whereAmIWillPlayBook || self.isPlaybackUnderWay
            },
            bluetoothMonitoring: settingsViewModel.bluetoothMonitoringEnabled,
            bluetoothDelay: settingsViewModel.bluetoothDisconnectDelay
        )
        // Apply the gesture-detector settings. Done after setup() so the
        // detector is ready before the first media command can arrive.
        nowPlayingService.updateGestureSettings(
            enabled: settingsViewModel.restartTimerGestureEnabled,
            pattern: settingsViewModel.restartTimerGesturePattern,
            window: settingsViewModel.restartTimerGestureWindow
        )
    }

    /// Check whether a notification should be handled by this reader instance.
    /// - Keyboard shortcuts include `sourceWindow`: accept the reader or one
    ///   of its attached sheets.
    /// - Menu commands have no source window: follow the current key window,
    ///   including a sheet attached to this reader.
    private func isTargetedNotification(_ notification: Notification) -> Bool {
        let sourceWindow = notification.userInfo?["sourceWindow"] as? PlatformWindow
        return WindowCommandRouting.shouldAccept(
            sourceWindow: sourceWindow,
            hostWindow: hostWindow,
            keyWindow: PlatformApplication.keyWindow
        )
    }

    private func setupNotifications() {
        let nc = notificationCenter

        // TextMouth becoming active looks for an edit of an open
        // audiobook's manifest made meanwhile outside Edit Manifest (FR18).
        nc.publisher(for: PlatformApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.lookForOutsideManifestEdit() }
            .store(in: &cancellables)

        nc.publisher(for: .togglePlayback)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.togglePlayPause()
            }
            .store(in: &cancellables)

        nc.publisher(for: .releaseMediaControls)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.releaseMediaControls()
            }
            .store(in: &cancellables)

        nc.publisher(for: .skipForward)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                let shiftHeld = notification.userInfo?["shiftHeld"] as? Bool ?? false
                self.skipForward(useShiftUnit: shiftHeld)
            }
            .store(in: &cancellables)

        nc.publisher(for: .skipBackward)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                let shiftHeld = notification.userInfo?["shiftHeld"] as? Bool ?? false
                self.skipBackward(useShiftUnit: shiftHeld)
            }
            .store(in: &cancellables)

        nc.publisher(for: .cycleForwardNavigationUnit)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.cyclePlaybackSkipUnit(direction: .forward)
            }
            .store(in: &cancellables)

        nc.publisher(for: .cycleBackwardNavigationUnit)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.cyclePlaybackSkipUnit(direction: .backward)
            }
            .store(in: &cancellables)

        nc.publisher(for: .increaseSpeed)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.stepSpeed(forward: true)
            }
            .store(in: &cancellables)

        nc.publisher(for: .decreaseSpeed)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.stepSpeed(forward: false)
            }
            .store(in: &cancellables)

        nc.publisher(for: .nextHeading)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.nextHeading()
            }
            .store(in: &cancellables)

        nc.publisher(for: .previousHeading)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.previousHeading()
            }
            .store(in: &cancellables)

        // Go to Page… (PG03).
        nc.publisher(for: .goToPage)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.requestGoToPage()
            }
            .store(in: &cancellables)

        // Next in Reading List and Previous in Reading List (FR09).
        nc.publisher(for: .nextInReadingList)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goThroughReadingList(.down)
            }
            .store(in: &cancellables)

        nc.publisher(for: .previousInReadingList)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goThroughReadingList(.up)
            }
            .store(in: &cancellables)

        // Next in Folder and Previous in Folder (0.2.5).
        nc.publisher(for: .nextInFolder)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goThroughFolder(.down)
            }
            .store(in: &cancellables)

        nc.publisher(for: .previousInFolder)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goThroughFolder(.up)
            }
            .store(in: &cancellables)

        nc.publisher(for: .addBookmark)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.toggleBookmarkAtCurrentPosition()
            }
            .store(in: &cancellables)

        nc.publisher(for: .nextBookmark)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goToNextBookmark()
            }
            .store(in: &cancellables)

        nc.publisher(for: .previousBookmark)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.goToPreviousBookmark()
            }
            .store(in: &cancellables)

        // W, and Playback > Where Am I?, speak the brief summary; W twice,
        // and Playback > Where Am I? Full Summary, the full one (FR12).
        nc.publisher(for: .whereAmI)
            .merge(with: nc.publisher(for: .whereAmIFull))
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.whereAmI(notification.name == .whereAmIFull ? .full : .brief)
            }
            .store(in: &cancellables)

        // Shift-Command-I speaks this reader's book's brief information,
        // and Shift-Command-I twice (Speak Full Info) its full information,
        // as the Library window speaks its selected row's (October 17).
        // Only the reader the key was pressed in, or the key one for a
        // menu command, speaks (`isTargetedNotification`).
        nc.publisher(for: .speakInfo)
            .merge(with: nc.publisher(for: .speakFullInfo))
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.speakInfo(notification.name == .speakFullInfo ? .full : .brief)
            }
            .store(in: &cancellables)

        nc.publisher(for: .copyReadingPosition)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.copyReadingPosition()
            }
            .store(in: &cancellables)

        // Restart-sleep-timer notification — fires from either the
        // keyboard shortcut or the experimental media-gesture detector.
        // The two paths target different windows:
        // - Keyboard path always carries `sourceWindow`, so the usual
        //   focused-window gate applies.
        // - Gesture path carries no sourceWindow because media keys
        //   don't belong to a window. AirPods presses also commonly
        //   arrive when the app is backgrounded (no key window). The
        //   right reader to respond is whichever one most recently
        //   owned a timer — the user is restarting THAT timer. Only
        //   that reader responds, not another window of the same book.
        //   Falls back to the focused window when no prior timer
        //   exists yet (first-ever press), or its reader has closed.
        nc.publisher(for: .restartSleepTimer)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let bookToken = String(self.book.id.uuidString.prefix(8))
                let readerToken = String(self.readerID.uuidString.prefix(8))
                let hasSourceWindow = notification.userInfo?["sourceWindow"] != nil
                let lastOwnerToken = self.sleepTimerService.lastOwnerID
                    .map { String($0.uuidString.prefix(8)) } ?? "none"
                SleepTimerService.log(
                    .event,
                    "RESTART_ROUTE_RECEIVED book=\(bookToken) reader=\(readerToken) "
                        + "sourceWindow=\(hasSourceWindow) lastOwner=\(lastOwnerToken)"
                )
                if notification.userInfo?["sourceWindow"] != nil {
                    guard self.isTargetedNotification(notification) else {
                        SleepTimerService.log(
                            .event,
                            "RESTART_ROUTE_REJECTED book=\(bookToken) reason=source-window-mismatch"
                        )
                        return
                    }
                } else if let lastOwner = self.sleepTimerService.lastOwnerID {
                    guard lastOwner == self.readerID else {
                        SleepTimerService.log(
                            .event,
                            "RESTART_ROUTE_REJECTED book=\(bookToken) reason=last-owner-mismatch"
                        )
                        return
                    }
                } else {
                    // No prior timer history — only the focused or
                    // sole window should respond.
                    guard self.hostWindow == nil
                          || self.hostWindow?.isKeyWindow == true
                          || self.hostWindow?.isMainWindow == true
                    else {
                        SleepTimerService.log(
                            .event,
                            "RESTART_ROUTE_REJECTED book=\(bookToken) reason=no-focused-window"
                        )
                        return
                    }
                }
                SleepTimerService.log(
                    .event,
                    "RESTART_ROUTE_ACCEPTED book=\(bookToken) timerActive=\(self.sleepTimerService.isActive)"
                )
                self.restartOrStartLastSleepTimer()
            }
            .store(in: &cancellables)

        // Settings changes apply to all reader windows (not window-specific)
        nc.publisher(for: .speechSettingsChanged)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // sleepTimerService.fadeOutDuration is captured at start()
                // time, so changing it mid-timer is intentionally a no-op:
                // the user committed to a fade duration when they started.
                // The next timer will pick up the new value automatically.
                // Re-apply per-book overrides (they take priority over global)
                self.applyLocalSpeechOverrides()
            }
            .store(in: &cancellables)

        // Observe Bluetooth settings and forward to NowPlayingService at runtime
        nc.publisher(for: .bluetoothSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.nowPlayingService.updateBluetoothSettings(
                    enabled: self.settingsViewModel.bluetoothMonitoringEnabled,
                    delay: self.settingsViewModel.bluetoothDisconnectDelay
                )
            }
            .store(in: &cancellables)

        // Observe gesture settings and push them to NowPlayingService.
        // Without this, toggling the feature on or changing the pattern
        // wouldn't take effect until the next book window opened.
        nc.publisher(for: .restartTimerGestureSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.nowPlayingService.updateGestureSettings(
                    enabled: self.settingsViewModel.restartTimerGestureEnabled,
                    pattern: self.settingsViewModel.restartTimerGesturePattern,
                    window: self.settingsViewModel.restartTimerGestureWindow
                )
            }
            .store(in: &cancellables)

        // A finished book continuing to this one. Claiming its request
        // starts playback once; a reader still loading claims it when
        // loading ends instead.
        nc.publisher(for: .continueToNextBook)
            .sink { [weak self] notification in
                guard let self, notification.nextBookID == self.book.id else { return }
                self.claimAutoplayRequest()
            }
            .store(in: &cancellables)
    }

    // MARK: - Content Loading

    /// What reading a book's files produced, handed from the background read
    /// to the reader on the main actor.
    struct LoadedContent {
        /// The book's chapters, with their index.
        let content: DocumentContent
        /// The index to save with the book when `shouldPersistContentIndex`.
        let index: BookContentIndex
        /// A multi-file audiobook's chapter files, where the book was read.
        let audioFiles: [String]?
        /// A segmented audiobook's clips, chapter by chapter.
        let audioSegments: [AudioSegment]?
        /// An audiobook's tags.
        let audioTags: AudioMetadata?
        /// Whether the index, or the version of the cache it was measured
        /// from, is new and must be saved with the book.
        let shouldPersistContentIndex: Bool
        /// The text cache format version the analysis vouches for.
        let cacheFormatVersion: String?
        /// The moves of the book's places for the reader to take, in order,
        /// on the main actor as it shows the text (`takeMovedPlaces(_:)`).
        /// In order: first an edit's taken as this load began (branch E),
        /// then a rebuild's during it (branch D), both already committed to
        /// the book's record; then the check at load's (branch E), whose
        /// places the reader saves as any change is, each move starting from
        /// where the one before it ended. Empty when nothing moved.
        var movedPlaces: [MovedPlaces] = []
        /// The pauses the book keeps between its chapters, from its
        /// manifest, read afresh at every load, from the index or not
        /// (`ChapterPauses.betweenTracks(of:inAudioFolder:)`).
        var chapterPauses = ChapterPauses.none
        /// Why an audiobook with a transcript shows none of its text, when
        /// the load knows (`TranscriptTextWithheld`); nil otherwise.
        var transcriptWithheld: TranscriptTextWithheld? = nil
        /// What the look at an audiobook of tracks' manifest found before
        /// the book was read (FR18): an edit made outside Edit Manifest,
        /// taken or refused, for the manifest editor once the book shows;
        /// nil for every other book.
        var manifestLook: BookManifestEditCheck? = nil
    }

    /// Start getting the book ready to read, showing Loading meanwhile.
    ///
    /// The book's library is checked first, off the main thread, since that
    /// reads file-system metadata (FR02). A book in a library that is not in
    /// a cloud location is read right away, in the same background step, as
    /// it always was. A book in a cloud location goes on through its cloud
    /// state (`continueOpening(in:found:)`): downloaded first when any of its
    /// files is only in the cloud, and then read without ever waiting on the
    /// network. A book whose package the library is moving is read once the
    /// move is over (`beginReadingForLoad()`, TODO P10).
    func loadContent() {
        isLoading = true
        guard beginReadingForLoad() else { return }
        let bookCopy = book
        let storage = cloudServices.storage
        let package = BookPackage(bookCopy)
        loadQueue.async { [weak self] in
            let location = storage.libraryLocation()
            if location.isCloud {
                let state = storage.state(of: package)
                DispatchQueue.main.async { [weak self] in
                    self?.continueOpening(in: location, found: state, at: bookCopy.filePath)
                }
                return
            }
            let result = Result { try ReaderViewModel.readContent(of: bookCopy) }
            DispatchQueue.main.async { [weak self] in
                self?.finishLoading(result, readFrom: bookCopy.filePath)
            }
        }
    }

    /// Reads `book`'s content, with an audiobook's tags, from `tagsURL` when
    /// given (the same file in the book's working copy) and otherwise from
    /// the book's own file. Runs on a background queue.
    ///
    /// The book's own edits are laid over the tags back on the main actor,
    /// from the reader's copy of the book as it is by then, so an edit the
    /// library makes while the book loads is shown too (TODO P10). An EPUB's
    /// package metadata is not read here, so no open waits for it: the
    /// reader takes it from the book's row, or reads it once the book shows
    /// (`showEPUBMetadata()`).
    ///
    /// A text book's reading text goes through `readingTexts`, this Mac's
    /// cache of the reading text of the large books opened lately (PERF22,
    /// `ReadingTextCache`): it is read from there when kept for the book's
    /// content.md as it is, and kept there after a parse otherwise.
    nonisolated static func readContent(
        of book: Book,
        audioTagsFrom tagsURL: URL? = nil,
        readingTexts: ReadingTextCache? = .shared
    ) throws -> LoadedContent {
        var book = book
        let url = book.bookFileURL
        let format = book.format
        // A text being edited in the user's editor has a saved edit checked
        // first (FR05), so the read never finds an edit that would look like
        // a stale cache and be rebuilt from the source (TODO T07). An edit
        // taken now is read by its analysis, its cache format current; an
        // edit that cannot be taken stops the read, which says why and where
        // the edit was kept, rather than rebuild the text over it. An
        // audiobook's transcript text is edited the same way, but its audio
        // still plays while such an edit stands: only its text is left out.
        var holdsTranscriptText = false
        // Why an audiobook with a transcript shows none of its text, for
        // Search in Book to say (`announceNoTextToSearch(hasTranscript:)`).
        var transcriptWithheld: TranscriptTextWithheld?
        // The moves of the book's places for the reader to take, in order:
        // an edit's, a rebuild's, then the check at load's.
        var movedPlaces: [MovedPlaces] = []
        switch BookTextEditSessions.shared.settlePendingEdit(of: book) {
        case .readTaken(let edit):
            book.contentAnalysisFields = edit.committed.contentAnalysisFields
            // The edit moved the book's places in its record, which this
            // copy of the book (made before the edit was taken) takes too,
            // so a rebuild's move and the check at load start from them;
            // the reader takes the same moves first of all (below).
            if let moved = edit.movedPlaces {
                book.takeMovedPlaces(original: moved.original, moved: moved.moved)
                movedPlaces.append(moved)
            }
        case .hold(let pending):
            guard format.isAudio else { throw pending }
            holdsTranscriptText = true
            transcriptWithheld = .editHeld(pending.refusal, keptCopy: pending.keptCopy)
        case .readAsUsual:
            break
        }
        // An audiobook of tracks whose manifest was edited outside Edit
        // Manifest (in an editor opened from Finder, on another Mac, or
        // while TextMouth was closed) takes the edit before it is read, as
        // a save through Edit Manifest is taken, so it opens rearranged
        // (FR18). The edit is committed to the record, which this copy of
        // the book follows, so the load reads the new index; the reader
        // takes the moves of its places as it shows the book.
        var manifestLook: BookManifestEditCheck?
        if format.isAudio, BookManifestEditing.mayHaveTrackFolder(book) {
            let found = BookManifestEditSessions.shared.look(at: book)
            if case .adopted(let edit) = found {
                book.contentAnalysisFields = edit.committed.contentAnalysisFields
                book.title = edit.title ?? book.title
                book.author = edit.author ?? book.author
            }
            manifestLook = found
        }
        let cacheOutdated = !format.isAudio
            && MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        let analysis = try BookContentAnalysisService.load(
            book: book,
            regenerateTextCache: cacheOutdated,
            readingTexts: readingTexts
        )
        // A rebuild of the text moved the book's places (T06's branch D):
        // the record takes them with the rebuilt text's analysis, each only
        // where it still holds it as it was, and the copy of the old text
        // goes once they are written. When the write fails or is dropped,
        // the copy stays and the next launch finishes the move. The reader
        // takes them into its own copy back on the main actor.
        if let moved = analysis.movedPlaces {
            _ = try? LibraryPersistenceService.saveContentAnalysis(
                for: book,
                index: analysis.index,
                cacheFormatVersion: analysis.cacheFormatVersion,
                movedPlaces: moved
            )
            movedPlaces.append(moved)
        }
        // The backstop for every path a rebuild did not take (a feed article
        // downloaded again, another Mac's text, an edit saved while
        // TextMouth was closed, a rebuild that could not finish): each place
        // of a text book is checked at the text it now has, and one whose
        // saved words are not at its numbers is found by them, with a silent
        // best guess for the rest (T06's branch E). The check starts from the
        // places as a rebuild's move left them. Nothing is committed here:
        // the reader takes the move into the row, which saves the row and
        // the record as any change is. All of it runs off the main thread,
        // where a large book's places are found.
        if !format.isAudio {
            if let moved = analysis.movedPlaces {
                book.takeMovedPlaces(original: moved.original, moved: moved.moved)
            }
            let before = book.relocatablePlaces
            if let outcome = PlaceRelocator.relocate(before, within: analysis.content, movedAt: Date()) {
                // Said only when the places changed: a book whose only
                // place stays as saved (nothing finds it) logs nothing at
                // each open.
                if outcome.places != before {
                    if outcome.counts.anythingMoved {
                        DiagnosticLog.event(.storage, outcome.counts.logLine(title: book.title))
                    }
                    movedPlaces.append(MovedPlaces(bookID: book.id, original: before, moved: outcome.places, snapshot: nil))
                }
            }
        }
        // An audiobook with a transcript reads as text too (FR05): the
        // transcript's text is laid over its chapters for the reader to show,
        // while the book keeps playing its audio, and its index takes the
        // text's layer when the text had to be written again.
        var content = analysis.content
        var index = analysis.index
        var transcriptIndexChanged = false
        if format.isAudio && !holdsTranscriptText {
            let transcript = TranscriptTextLoader.load(for: book, audioIndex: analysis.index, readingTexts: readingTexts)
            content.transcript = transcript.text
            index = transcript.index
            transcriptIndexChanged = transcript.indexChanged
            transcriptWithheld = transcript.withheld
        }

        var audioTags: AudioMetadata?
        if format.isAudio {
            let tagged = tagsURL ?? url
            audioTags = (try? AsyncBridge.waitForResult(reading: tagged, timeLimit: AsyncBridge.audioTagsTimeLimit) { await AudioPlaybackService.extractFullMetadata(from: tagged) }) ?? AudioMetadata()
        }

        return LoadedContent(
            content: content,
            index: index,
            audioFiles: analysis.audioFilePaths,
            audioSegments: analysis.audioSegments,
            audioTags: audioTags,
            shouldPersistContentIndex: !analysis.usedPersistedIndex
                || transcriptIndexChanged
                || book.contentIndexVersion != BookContentIndex.currentVersion
                || (!format.isAudio
                    && book.cacheFormatVersion != MarkdownCacheService.currentCacheVersion),
            cacheFormatVersion: analysis.cacheFormatVersion,
            movedPlaces: movedPlaces,
            // The manifest is read afresh, so a load from the saved index
            // keeps the pauses a fresh analysis would find.
            chapterPauses: format.isAudio ? ChapterPauses.betweenTracks(of: analysis.index, inAudioFolder: url) : .none,
            transcriptWithheld: transcriptWithheld,
            manifestLook: manifestLook
        )
    }

    /// Shows what a read of the book at `filePath` produced, or why it
    /// failed. A closed reader has nothing left to show.
    private func finishLoading(_ result: Result<LoadedContent, Error>, readFrom filePath: String) {
        guard !hasClosed else { return }
        switch result {
        case .success(let loaded):
            showLoadedContent(loaded, readFrom: filePath)
        case .failure(let error):
            showLoadFailure(error, readFrom: filePath)
        }
    }

    /// Shows `loaded`, read from the book at `filePath`: its chapters, its
    /// headings, its metadata (an EPUB's from the book's row, or read once
    /// the book shows), and its audio files, with the saved position kept
    /// within the book. Saves a new index, and starts playing for a
    /// finished book that continued to this one while it loaded; a text
    /// book that does not start playing has the speech of the chapter it
    /// opened at prepared in the background (`prepareOpenedChapterSpeech()`).
    func showLoadedContent(_ loaded: LoadedContent, readFrom filePath: String) {
        let parsed = loaded.content
        if let audioFiles = loaded.audioFiles {
            // A move the library made while the book loaded left
            // the files it loaded from behind (TODO P10).
            audioChapterFiles = book.filePath == filePath
                ? audioFiles
                : audioChapterFilesAtCurrentLocation(audioFiles, index: parsed.contentIndex)
        }
        if let segs = loaded.audioSegments {
            audioSegments = segs
        }
        chapterPauses = loaded.chapterPauses
        // Assigning content also publishes its headings.
        content = parsed
        transcriptWithheld = loaded.transcriptWithheld
        showEPUBMetadata()
        audioMetadata = loaded.audioTags.map { book.mergingEditableAudioMetadata($0) }

        // The places the load moved come first, in order (a rebuild's, then
        // the check at load's), so that the opening place, the opened
        // place's anchor (`noteLoadedTextForAnchors`), the anchor capture,
        // and the position the load saves all read the moved ones, not the
        // old numbers in the new text (T06's branches D and E).
        for moved in loaded.movedPlaces {
            takeMovedPlaces(moved)
        }
        // So do the moves of an audiobook's places to their tracks that an
        // edit of its manifest made, taken as the book loaded (FR18).
        if case .adopted(let edit)? = loaded.manifestLook {
            takeMovedTrackPlaces(edit.movedPlaces)
        }

        // Bring the saved place into the book as loaded: its chapters and
        // their lengths can change when the book is imported again or its
        // text is extracted or edited anew. A place past its chapter's end
        // opens at that end, which in the last chapter is the book's end, so
        // a finished book opens finished (T06, question 7; see
        // `openingPlace(of:savedGlobalOffset:in:)`). A place saved with its
        // words was found by them first (above); this clamp takes the places
        // saved without words, which nothing can find without the old text.
        let saved = TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset)
        let opening = Self.openingPlace(of: saved, savedGlobalOffset: savedGlobalOffset(of: saved), in: parsed)
        if opening != saved {
            currentChapterIndex = opening.chapter
            currentCharacterOffset = opening.offset
        }
        // Every place saved from now on takes its words from this text, but
        // the place the book opened at keeps the words it was saved with
        // while the cursor stays there; the bookmarks and skipped headings
        // saved before anchors take theirs from it now (T06).
        noteLoadedTextForAnchors(cacheFormatVersion: loaded.cacheFormatVersion)
        captureMissingAnchorsAtLoad()
        // A book that played to its end was saved exactly there, and opens
        // finished, as it rested before TextMouth quit (TODO P07): its next
        // backward skip plays its end again, and Play does what Play does at
        // the end. Any other place opens a book that is not finished.
        hasFinishedBook = cursorRestsAtEnd
        // This reader's sleep timer for the end of the heading waits for the
        // end of the heading the cursor is in, as the headings are now: one
        // set while the book loaded found no headings yet (finding #787).
        refreshSleepTimerHeading()

        isLoading = false

        if loaded.shouldPersistContentIndex {
            libraryViewModel.updateContentIndex(
                bookID: book.id,
                index: loaded.index,
                cacheFormatVersion: loaded.cacheFormatVersion
            )
        }

        // Save position with global offset now that we have chapter data
        savePosition()
        refreshPlaybackUI()
        // A sleep timer the previous book handed over is taken before
        // anything plays: a timer that ran out meanwhile ends listening, so
        // the book is not started for it (0.2.5).
        claimSleepTimerHandOver()
        // A window a switch made this reader's has its focus seen to now that
        // the book has loaded (`attach(to:)`).
        placeFocusAfterSwitchIfDue()
        // A match Search Library opened this book at is moved to now that
        // the text is loaded, before any playback that is due starts from
        // the cursor it leaves.
        claimLibrarySearchJump()
        // A finished book may have continued to this one while
        // it loaded: start playing for it now.
        claimAutoplayRequest()
        // Otherwise get the speech of the chapter the cursor is in ready
        // off the main thread, so Play finds it prepared.
        prepareOpenedChapterSpeech()
        // An edit of the book's text taken while it loaded replaces the
        // text it loaded (FR05), as does an audiobook's transcript text
        // saved or deleted meanwhile, and an audiobook's arrangement an
        // edit of its manifest gave (FR17).
        showEditedTextWaitingForLoad()
        showTranscriptWaitingForLoad()
        showManifestEditWaitingForLoad()
        // An edit of the manifest the load took, or refused, is given to the
        // library and announced now that the book shows (FR18).
        reportManifestLookAtLoad(loaded.manifestLook)
    }

    /// Shows why the book at `filePath` could not be read, in place of the
    /// reader, unless the library moved the book's files from under the
    /// load: then the book loads again, from where it is now.
    func showLoadFailure(_ error: Error, readFrom filePath: String) {
        // The library moved the book while it loaded, or is moving it,
        // so the files the load read may have gone from under it: load
        // it again from where the book is, once any move is over
        // (TODO P10).
        if loadAgainAfterMove(ofFilesReadAt: filePath) {
            return
        }
        errorMessage = error.localizedDescription
        isLoading = false
        loadHeldByTextEdit = error is BookTextEditPending
        // A book that cannot load cannot play for a finished
        // book that continued to it; its error shows instead. Nor can it
        // take over a sleep timer, which would count toward pausing nothing.
        discardAutoplayRequest()
        // Said once the error view's own focus has read the reason.
        releaseSleepTimerHeld(forBook: book.id, afterTheReason: true)
    }

    // MARK: - EPUB Metadata

    /// Shows an EPUB's package metadata, which the metadata editor starts
    /// from, without making the open wait for it: from the book's row, with
    /// the book, when the row keeps all of it (`Book.keptEPUBMetadata`), and
    /// otherwise read from the EPUB off the main thread, arriving once the
    /// book shows (`readEPUBMetadataInBackground()`), and kept on the row
    /// then, so that it is read once. Shows nothing for any other format,
    /// and reads nothing again once metadata shows.
    func showEPUBMetadata() {
        guard book.format == .epub else { return }
        if let kept = book.keptEPUBMetadata {
            epubMetadata = kept
        } else if epubMetadata == nil {
            readEPUBMetadataInBackground()
        }
    }

    /// Reads the EPUB's package metadata from its file off the main thread
    /// (`readEPUBMetadata`), at a priority below the work the listener waits
    /// for, keeps it on the book's row and record so that no later open
    /// reads it again (`keepEPUBMetadataReadFromFile(_:)`), and shows it with
    /// the book's own edits laid over it, from the reader's copy of the book
    /// as it is by then, so an edit the library made meanwhile is shown too
    /// (TODO P10). Nothing is shown when the reader has closed, when it
    /// shows metadata by then (its metadata editor saved an edit), or when
    /// the file cannot be read: the metadata editor then opens the library's
    /// Book Info, as for any book without metadata of its own. A file only
    /// in the cloud is never downloaded for this: its read is refused at
    /// once, so nothing is shown or kept for it.
    private func readEPUBMetadataInBackground() {
        let file = book.bookFileURL
        let read = readEPUBMetadata
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let metadata = try? read(file)
            DispatchQueue.main.async { [weak self] in
                guard let self, let metadata, !self.hasClosed else { return }
                self.keepEPUBMetadataReadFromFile(metadata)
                guard self.epubMetadata == nil else { return }
                self.epubMetadata = self.book.mergingEditableEPUBMetadata(metadata)
            }
        }
    }

    /// Keeps `metadata`, read from the book's EPUB file because the book's
    /// row lacked some of it, on the library's row and in the book's record
    /// (bookInfo.json), as an import keeps a new book's
    /// (`Book.keepEPUBMetadata(readFromFile:)`), so that every later open
    /// shows it from the row with the book and reads nothing. Only the
    /// fields the row lacks are given, so an edit made meanwhile stands, and
    /// the book is saved once: a row that keeps all of it by now, or a book
    /// no longer in the library, is not saved. A record only in the cloud is
    /// not written; the library index alone takes the fields then, as for
    /// any save (`LibraryPersistenceService`). The reader's own copy of the
    /// book takes the same fields.
    private func keepEPUBMetadataReadFromFile(_ metadata: EPUBMetadata) {
        book.keepEPUBMetadata(readFromFile: metadata)
        guard let row = libraryViewModel.bookByID(book.id), row.format == .epub,
              row.keptEPUBMetadata == nil else { return }
        libraryViewModel.updateBook(id: book.id) { $0.keepEPUBMetadata(readFromFile: metadata) }
    }

    // MARK: - Text Display Window

    /// Maximum number of characters to render in the SwiftUI Text view.
    /// Chapters under this limit are shown in full. Larger chapters show
    /// a sliding window around the current reading position so the UI
    /// stays responsive. The full text remains in memory for TTS.
    /// Internal (not private) so tests can cut their texts to it.
    static let maxDisplayChars = 20_000

    /// Return the text to display in the reader view. For small chapters,
    /// returns the full text. For large chapters, returns a window of text
    /// around the current character offset, holding it, that begins and
    /// ends on whole words (`VisibleTextWindowPolicy.bounds`).
    private func makeVisibleTextWindow(_ fullText: String, centeredAt offset: Int) -> VisibleTextWindow {
        guard fullText.utf16Length > Self.maxDisplayChars else {
            return VisibleTextWindow(
                text: fullText,
                startOffset: 0,
                endOffset: fullText.utf16Length
            )
        }

        let bounds = VisibleTextWindowPolicy.bounds(in: fullText, around: offset, maximumLength: Self.maxDisplayChars)
        let start = fullText.index(atUTF16Offset: bounds.lowerBound)
        let end = fullText.index(atUTF16Offset: bounds.upperBound)
        return VisibleTextWindow(
            text: String(fullText[start..<end]),
            startOffset: fullText.utf16Offset(of: start),
            endOffset: fullText.utf16Offset(of: end)
        )
    }

    /// Refresh the throttled UI mirrors of playback position and visible text.
    /// This keeps the raw cursor precise while letting SwiftUI update on a
    /// slower cadence that is easier on VoiceOver.
    private func schedulePlaybackUIRefresh() {
        guard !isLoading else { return }

        let chapterIndex = currentChapterIndex
        let offset = currentCharacterOffset
        pendingPlaybackUIRefresh = PlaybackUIRefreshSnapshot(
            chapterIndex: chapterIndex,
            offset: offset
        )

        guard playbackUIRefreshWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.drainPlaybackUIRefresh()
        }
        playbackUIRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.playbackUIRefreshInterval,
            execute: workItem
        )
    }

    /// Apply the latest pending snapshot, then reschedule if more updates
    /// arrived while the refresh was running.
    private func drainPlaybackUIRefresh() {
        playbackUIRefreshWorkItem = nil
        guard let snapshot = pendingPlaybackUIRefresh else { return }
        pendingPlaybackUIRefresh = nil
        refreshPlaybackUI(
            chapterIndex: snapshot.chapterIndex,
            offset: snapshot.offset
        )
        // The reader header has just learned the heading the cursor is in,
        // and an End of heading sleep timer learns here, at this pace rather
        // than with every spoken word, whether playback has left its heading
        // (finding #787).
        stopForSleepTimerIfPlaybackReachedHeadingEnd()

        if pendingPlaybackUIRefresh != nil {
            schedulePlaybackUIRefresh()
        }
    }

    /// Update the displayed offset and cached reader text using a snapshot of
    /// the current playback position. Showing a book's edited text calls it
    /// too, forcing the visible text to be drawn from the new chapters
    /// (`ReaderViewModel+EditedText`).
    func refreshPlaybackUI(
        chapterIndex: Int? = nil,
        offset: Int? = nil,
        forceVisibleTextRefresh: Bool = false
    ) {
        guard let content = content,
              !content.chapters.isEmpty else {
            if displayChapterIndex != 0 { displayChapterIndex = 0 }
            if displayCharacterOffset != 0 { displayCharacterOffset = 0 }
            if !displayVisibleTextWindow.isEmpty { displayVisibleTextWindow = "" }
            visibleTextWindowState = nil
            return
        }

        let resolvedChapterIndex = chapterIndex ?? currentChapterIndex
        guard resolvedChapterIndex >= 0,
              resolvedChapterIndex < content.chapters.count else {
            if displayChapterIndex != 0 { displayChapterIndex = 0 }
            if displayCharacterOffset != 0 { displayCharacterOffset = 0 }
            if !displayVisibleTextWindow.isEmpty { displayVisibleTextWindow = "" }
            visibleTextWindowState = nil
            return
        }

        let resolvedChapterText = content.chapters[resolvedChapterIndex].text
        let resolvedOffset = max(0, min(offset ?? currentCharacterOffset, resolvedChapterText.utf16Length))

        if displayChapterIndex != resolvedChapterIndex {
            displayChapterIndex = resolvedChapterIndex
        }
        if displayCharacterOffset != resolvedOffset {
            displayCharacterOffset = resolvedOffset
        }

        // What the text area shows: the chapter's own text, or, for an
        // audiobook with a transcript, the transcript's text at the time
        // the cursor stands for (FR05).
        let shown = Self.shownText(of: content, chapterIndex: resolvedChapterIndex, cursorOffset: resolvedOffset)
        let shouldRefreshVisibleText = forceVisibleTextRefresh
            || shouldRefreshVisibleTextWindow(
                chapterIndex: resolvedChapterIndex,
                offset: shown.offset,
                chapterTextLength: shown.text.utf16Length
            )
        if shouldRefreshVisibleText {
            let window = makeVisibleTextWindow(shown.text, centeredAt: shown.offset)
            let nextState = VisibleTextWindowState(
                chapterIndex: resolvedChapterIndex,
                startOffset: window.startOffset,
                endOffset: window.endOffset
            )
            visibleTextWindowState = nextState
            if displayVisibleTextWindow != window.text {
                displayVisibleTextWindow = window.text
            }
        } else if visibleTextWindowState == nil {
            let window = makeVisibleTextWindow(shown.text, centeredAt: shown.offset)
            visibleTextWindowState = VisibleTextWindowState(
                chapterIndex: resolvedChapterIndex,
                startOffset: window.startOffset,
                endOffset: window.endOffset
            )
            if displayVisibleTextWindow != window.text {
                displayVisibleTextWindow = window.text
            }
        }
    }

    /// The text the reader shows for chapter `chapterIndex` of `content`,
    /// and where in it the cursor, at `cursorOffset` in the chapter, falls:
    /// the chapter's own text and the cursor itself; or, for an audiobook
    /// with a transcript (FR05), whose chapters stand for time, the
    /// chapter's transcript text and the start of the sentence heard at the
    /// time the cursor stands for (`TranscriptText`). The window shown is
    /// cut from that text around that place, so it follows the narration
    /// sentence by sentence.
    nonisolated static func shownText(
        of content: DocumentContent,
        chapterIndex: Int,
        cursorOffset: Int
    ) -> (text: String, offset: Int) {
        if let transcript = content.transcript, let text = transcript.chapterText(chapterIndex) {
            return (text, transcript.textOffset(atAudioOffset: cursorOffset, inChapter: chapterIndex))
        }
        return (content.chapters[chapterIndex].text, cursorOffset)
    }

    private func shouldRefreshVisibleTextWindow(
        chapterIndex: Int,
        offset: Int,
        chapterTextLength: Int
    ) -> Bool {
        let state = visibleTextWindowState
        return VisibleTextWindowPolicy.shouldRefresh(
            chapterTextLength: chapterTextLength,
            maximumDisplayLength: Self.maxDisplayChars,
            cachedChapterIndex: state?.chapterIndex,
            windowStart: state?.startOffset,
            windowEnd: state?.endOffset,
            chapterIndex: chapterIndex,
            offset: offset,
            guardFraction: Self.visibleTextWindowGuardFraction
        )
    }

    var isPlaybackActivelyAdvancing: Bool {
        isCurrentlyPlaying && !isCurrentlyPaused
    }

    // MARK: - Error Alert

    /// An error shown as an alert over a loaded reader.
    struct ErrorAlert: Equatable {
        /// The alert's title, naming the kind of problem.
        let title: String
        /// What went wrong and what to do: the reader's `errorMessage`.
        let message: String
        /// Whether the alert offers Retry, as it does for audio that could
        /// not be played, which may play once its file is back.
        let offersRetry: Bool
        /// The retry button's title: "Retry" for audio that could not be
        /// played, and "Try Again" for a chapter that could not be got from
        /// the cloud (FR02), as the download view words it.
        var retryTitle = "Retry"
    }

    /// `errorMessage` while no content has loaded: the book itself could
    /// not be opened, so the message is shown in place of the reader.
    var loadErrorMessage: String? {
        content == nil ? errorMessage : nil
    }

    /// `errorMessage` once content has loaded, as an alert over the reader,
    /// which stays usable behind it. Nil when there is no such error.
    var errorAlert: ErrorAlert? {
        guard content != nil, let errorMessage else { return nil }
        // A chapter whose files could not be got from the cloud stopped the
        // reader at that chapter, which may play once they are here (FR02).
        if cloudSession.chapterFailure != nil {
            return ErrorAlert(
                title: "Chapter Not Downloaded",
                message: errorMessage,
                offersRetry: true,
                retryTitle: "Try Again"
            )
        }
        return ErrorAlert(
            title: audioPlaybackFailure == nil ? "Error" : "Playback Problem",
            message: errorMessage,
            offersRetry: audioPlaybackFailure != nil
        )
    }

    /// Close the error alert, forgetting the error it showed and, for an
    /// audio failure or a chapter not got from the cloud, the failure behind
    /// it.
    func dismissErrorAlert() {
        errorMessage = nil
        audioPlaybackFailure = nil
        cloudSession.chapterFailure = nil
    }

    /// Whether Release Media Controls is offered: while this reader holds
    /// TextMouth's media controls, its book shown in the system's Now
    /// Playing, playing or paused, so that macOS sends the AirPods and the
    /// media keys here (`NowPlayingSession.holdsMediaControls`), and only
    /// then, since only then is there anything to release. That covers a
    /// book that plays or is paused; a finished book resting at its end
    /// (`hasFinishedBook`); and a book shown paused where its speech stopped
    /// on a refusal (`showPlaybackStoppedAfterRefusal(_:)`) or where its sleep
    /// timer stopped it, neither of which was offered it before. A book
    /// whose controls another book has taken, by playing, has nothing to
    /// release, and is not offered it (REV07, speech finding 5); nor is a
    /// book that released them, until it plays again.
    ///
    /// Nothing this reader publishes follows another reader's taking the
    /// controls, so its window asks again as it becomes key
    /// (`windowBecameKey()`).
    var canReleaseMediaControls: Bool {
        !mediaControlsReleased && nowPlayingService.holdsMediaControls
    }

    /// This reader's window became key. The reader becomes the focused
    /// owner of TextMouth's media session, which a Play from the AirPods
    /// starts while no book plays (`NowPlayingSession.focus()`), and its
    /// window publishes afresh what the menus read of it: whether the
    /// reader holds the media controls (`canReleaseMediaControls`) changes
    /// as another book takes them while this window is in the background,
    /// and nothing the window observes follows that.
    func windowBecameKey() {
        nowPlayingService.focus()
        objectWillChange.send()
    }

    /// UI-facing global offset, derived from the throttled display cursor.
    var displayCurrentGlobalOffset: Int {
        content?.globalOffset(chapterIndex: displayChapterIndex, localOffset: displayCharacterOffset) ?? 0
    }

    /// UI-facing percent complete, derived from the throttled display cursor.
    var displayPercentComplete: Double {
        content?.percentComplete(globalOffset: displayCurrentGlobalOffset) ?? 0
    }

    /// UI-facing remaining time, derived from the throttled display cursor.
    var displayTimeRemaining: TimeInterval {
        ReadingTimeEstimator.remaining(
            totalDuration: totalEstimatedTime,
            globalOffset: displayCurrentGlobalOffset,
            totalCharacterCount: content?.totalCharacterCount ?? 0
        )
    }

    var displayFormattedTimeRemaining: String {
        TimeFormatting.format(displayTimeRemaining)
    }

    var displayFormattedPercentComplete: String {
        String(format: "%.1f%%", displayPercentComplete)
    }

    // MARK: - Position Saving

    /// Persist the current reading position to the library
    func savePosition() {
        guard content != nil else { return }
        let position = makeCurrentReadingPosition()
        libraryViewModel.persistReadingPosition(bookID: book.id, position: position)
        lastPersistedCheckpoint = position.lastUpdated
        notePlaceSaved(position)
    }

    /// Persist the current reading position only when it moved since the
    /// last durable save: the quit's save (`PlaybackMemoryGuard.
    /// saveEveryOpenReaderPosition()`). A reader at rest writes nothing, so
    /// a quit does not date its old place anew, nor write the library's
    /// index from a copy that another Mac (on a shared library) has since
    /// moved on from. A reader that played since its last save always
    /// counts as moved, as does one that never saved.
    func savePositionIfMoved() {
        guard content != nil else { return }
        let place = TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset)
        guard hasPlayedSinceSave || lastSavedPlace != place else { return }
        savePosition()
    }

    /// Record that `position` was just saved durably: the place the next
    /// `savePositionIfMoved()` compares with, and no live move is waiting.
    private func notePlaceSaved(_ position: ReadingPosition) {
        lastSavedPlace = TextPlace(chapter: position.chapterIndex, offset: position.characterOffset)
        hasPlayedSinceSave = false
    }

    /// Builds the one canonical snapshot used by reader persistence and live
    /// library estimates, preventing formula inputs from drifting apart. A
    /// text book's place carries the words around it (T06), by which a
    /// later text of the book can find it again (`anchorToSave(at:)`).
    private func makeCurrentReadingPosition() -> ReadingPosition {
        ReadingPosition(
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            globalCharacterOffset: currentGlobalOffset,
            anchor: anchorToSave(at: TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset))
        )
    }

    /// Publishes at most once per second and periodically upgrades a live
    /// snapshot to a durable checkpoint while playback remains active.
    private func scheduleLivePositionPublish() {
        guard !hasClosed, content != nil, livePositionWorkItem == nil else { return }
        let elapsed = Date().timeIntervalSince(lastLivePositionPublish)
        let delay = max(0, Self.livePositionPublishInterval - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.hasClosed, self.content != nil else { return }
            self.livePositionWorkItem = nil
            self.publishLivePosition(now: Date())
        }
        livePositionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Applies the latest cursor to the shared library and persists every
    /// thirty seconds during active playback to bound crash-related data loss.
    private func publishLivePosition(now: Date) {
        let position = makeCurrentReadingPosition()
        let isActivelyPlaying: Bool
        if isAudioBook {
            isActivelyPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
        } else {
            isActivelyPlaying = speechService.isSpeaking && !speechService.isPaused
        }
        if PlaybackCheckpointPolicy.shouldPersist(
            isActivelyPlaying: isActivelyPlaying,
            lastCheckpoint: lastPersistedCheckpoint,
            now: now
        ) {
            libraryViewModel.persistReadingPosition(bookID: book.id, position: position)
            lastPersistedCheckpoint = now
            notePlaceSaved(position)
        } else {
            libraryViewModel.updateLiveReadingPosition(bookID: book.id, position: position)
            hasPlayedSinceSave = true
        }
        lastLivePositionPublish = now
        // With the position published, see whether the next episode of a
        // feed is due to be downloaded (FR19, task C): cheap guards first.
        predownloadNextEpisodeIfDue()
    }

    /// Perform actor-isolated window teardown explicitly. Swift deinitializers
    /// are nonisolated, so shared UI services must be released while the view
    /// model is still on the main actor.
    func close() {
        guard !hasClosed else { return }
        hasClosed = true
        // A closed reader hands nothing over when the next episode arrives.
        nextEpisodeWait = nil
        // Nor does it look any further for a Search Library match that moved.
        cancelLibraryJumpSearch()
        // A download the reader waits for is stopped, and the book's state
        // found afterwards recorded for the library list (FR02).
        endCloudWorkForClose()
        playbackUIRefreshWorkItem?.cancel()
        livePositionWorkItem?.cancel()
        livePositionWorkItem = nil
        // stop() records the stopped timestamp and persists when playback was
        // active or paused. The explicit save also captures navigation made
        // while stopped, and is a no-op until content has loaded.
        stop()
        savePosition()
        stopWhereAmISynthesizer()
        nowPlayingService.clearNowPlaying()
        nowPlayingService.close()
        // Stop the shared sleep timer iff this reader owned it. With the
        // singleton service, the timer would otherwise keep ticking
        // after our window closed — its callbacks captured `self`
        // weakly so they'd no-op, but the wall-clock countdown would
        // still run pointlessly until expiration. Owner check keeps us
        // from cancelling a timer another window started, even one of
        // the same book. A media gesture restarting the timer then goes
        // to the focused reader rather than to this closed one.
        //
        // A timer held for the next book (0.2.5), by a move announced before
        // this window closed, goes on: the reader that takes the book adopts
        // it, and stopping it here would end a timer the listener means to
        // keep.
        if sleepTimerService.ownerID == readerID, !sleepTimerService.isHeld(from: readerID) {
            sleepTimerService.stop()
        }
        sleepTimerService.forgetLastOwner(readerID)
        // Playback has stopped, so nothing reads the working copy any more
        // (FR02).
        removeWorkingCopy()
        libraryViewModel.bookUpdates.unwatch(book.id)
        libraryViewModel.unregisterOpenBook(book.id)
        // A finished book the reading list is to drop, which this reader held
        // on the list, leaves it now.
        releaseFinishedBookOnReadingList()
        // A timer held for this reader's book, which it never took because its
        // window closed while the book loaded, is stopped without a word, as
        // closing the window a timer belongs to stops it: nothing will play it.
        // Only when no reader of the book is left: another window of the same
        // book takes the timer (W6).
        if !bookIsOpenCheck(book.id) {
            sleepTimerService.cancelHeld(forBook: book.id)
        }
        // Last, once nothing above needs the book's text.
        releaseWhatGrowsWithTheBook()
    }

    /// Lets go of everything a closed reader holds that grows with its book
    /// (PERF27). SwiftUI keeps a closed reader window, and with it this
    /// reader, for the rest of the session, so without this every book
    /// opened and closed kept its whole text and the last chapter's rendered
    /// speech (tens of megabytes for a long chapter) until the app quit.
    ///
    /// Released: the subscriptions, so a closed reader reacts to nothing;
    /// the look-ahead (which `stop()` has already dropped for a text book);
    /// the text speech was speaking and the rendered speech of the chapter
    /// last played, through `SpeechService.releaseSpeech()`, which makes no
    /// engine to do it; the offset maps of that speech; the text window the
    /// reader showed; an audiobook's lists of files and clips; and the
    /// book's content, with its headings. An audiobook's player and its item
    /// went with `stop()`. What is left is the reader itself and its
    /// services, whose size does not depend on the book.
    private func releaseWhatGrowsWithTheBook() {
        cancellables.removeAll()
        discardLookAhead()
        speechService.releaseSpeech()
        currentTransformation = nil
        currentOffsetMap = nil
        pendingPlaybackUIRefresh = nil
        visibleTextWindowState = nil
        displayVisibleTextWindow = ""
        audioChapterFiles = []
        audioSegments = []
        chapterPauses = .none
        // Also empties `headings`, which follow the content.
        content = nil
    }

}

// MARK: - Helpers

/// Helper delegate for the Where Am I synthesizer (separate from the book
/// speech service). It hands each end of an announcement, finished or
/// cancelled, to the main queue with the utterance that ended, held as a
/// `ReportedUtterance`, for the reader to compare with the announcement
/// speaking (`ReaderViewModel.whereAmISynthesizerFinished(_:)` and
/// `whereAmISynthesizerCancelled(_:)`).
///
/// `@unchecked Sendable`: its two properties are constants, and each runs
/// only on the main queue, where the synthesizer's callbacks send them.
final class WhereAmIDelegateHelper: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// Told of an utterance that finished by itself.
    let onFinished: (ReportedUtterance) -> Void
    /// Told of an utterance that was cancelled: by the reader's own stop,
    /// or by the system, as when the speech engine refuses its text.
    let onCancelled: (ReportedUtterance) -> Void

    init(
        onFinished: @escaping (ReportedUtterance) -> Void,
        onCancelled: @escaping (ReportedUtterance) -> Void
    ) {
        self.onFinished = onFinished
        self.onCancelled = onCancelled
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            self?.onFinished(finished)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelled = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            self?.onCancelled(cancelled)
        }
    }
}
