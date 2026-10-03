import SwiftUI
import Combine
import AppKit
import AVFoundation
import os.log

enum VisibleTextWindowPolicy {
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

    @Published var content: DocumentContent? {
        // Derive the published heading list from whatever content the reader
        // holds, so the headings panel and every heading-based location label
        // always count exactly the same headings.
        didSet { headings = content?.allHeadings ?? [] }
    }
    @Published var currentChapterIndex = 0 {
        didSet {
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
    /// Every heading in the book, in reading order: the headings panel's rows
    /// and the list that heading numbers count. Kept in step with `content`.
    @Published var headings: [Heading] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var epubMetadata: EPUBMetadata?
    @Published var audioMetadata: AudioMetadata?

    /// Republished from speechService so SwiftUI views update when playback state changes
    @Published var isCurrentlyPlaying = false
    @Published var isCurrentlyPaused = false

    /// True while the "Where Am I?" announcement is speaking
    @Published var isWhereAmISpeaking = false

    /// Current WPM — forwarded from speechService so SwiftUI views update
    @Published var currentWPM: Double = 200

    let speechService = SpeechService()
    /// Shared singleton — there is exactly one sleep timer in the app.
    /// Owner-scoped pause/resume calls pass `book.id` so other windows'
    /// playback events don't accidentally affect this book's timer.
    let sleepTimerService = SleepTimerService.shared
    /// Every reader window receives a unique media owner, even when two
    /// windows happen to show the same book.
    lazy var nowPlayingService = NowPlayingSession(
        ownerID: UUID(),
        diagnosticLabel: "book-\(book.id.uuidString.prefix(8))"
    )
    /// Text substitution rules applied to every chapter before it is spoken:
    /// the shared rules edited in Substitutions settings, unless the reader
    /// was created with its own.
    let substitutionService: TextSubstitutionService
    /// Where Continue to Next Book leaves its requests to start playing:
    /// the shared store, unless the reader was created with its own.
    let autoplayRequests: ReaderAutoplayRequests
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
    weak var hostWindow: NSWindow?

    /// Separate synthesizer for "Where Am I?" announcements (not the book reader).
    /// Accessed from WhereAmI and Playback extensions.
    let whereAmISynth = AVSpeechSynthesizer()
    /// Whether playback was active before "Where Am I?" interrupted it.
    /// Accessed from WhereAmI and Playback extensions.
    var wasPlayingBeforeWhereAmI = false
    /// Set when playback was paused because the system audio route changed
    /// (for example AirPods disconnecting). The next resume must recreate
    /// the active playback backend so audio binds to the newly-current
    /// output device instead of continuing a graph/synth paused on the old
    /// route. Also set when the library moves a paused audiobook's files, so
    /// resuming plays them from where they are then instead of from a player
    /// still holding the old place (TODO P10).
    var restartPlaybackBackendOnNextResume = false
    /// The revision of the latest library update this reader has applied to
    /// its copy of the book (see `LibraryBookUpdates`); an update that is
    /// not newer is ignored. Written only by `applyLibraryUpdate(_:)` and
    /// when the reader starts watching its book.
    var appliedLibraryRevision = 0
    /// Audio that was playing when the library said the book's package was
    /// about to move, set aside until the move ends and playback goes on
    /// from the cursor (TODO P10); nil the rest of the time.
    var audioPausedForMove: AudioPausedForMove?
    /// True after the user explicitly releases Now Playing / headphone media
    /// controls for this open reader. Starting playback in TextMouth clears it.
    @Published var mediaControlsReleased = false
    /// Track when "Where Am I?" was last triggered for brief->full escalation.
    /// Accessed from WhereAmI extension.
    var lastWhereAmITime: Date = .distantPast
    /// Text of the most recent VoiceOver announcement, recorded even when no
    /// window can post it, so regression tests can verify spoken wording.
    /// Written only by `announceToVoiceOver(_:)`.
    var lastAnnouncement: String?

    /// Base offset for word-spoken callback tracking
    var utteranceBaseOffset: Int = 0
    private var cancellables = Set<AnyCancellable>()
    /// Coalesces rapid playback cursor changes into a single UI refresh.
    private var playbackUIRefreshWorkItem: DispatchWorkItem?
    /// Coalesces word-level cursor changes before publishing to library rows.
    private var livePositionWorkItem: DispatchWorkItem?
    private var lastLivePositionPublish = Date.distantPast
    private var lastPersistedCheckpoint: Date?
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
    ///   - notificationCenter: Where the reader listens for commands and for
    ///     Continue to Next Book, and posts its own Continue to Next Book.
    ///     Tests pass their own, so their notifications never reach the
    ///     running app's windows.
    ///   - renderScheduler: Renders the next chapter ahead of time. Nil uses
    ///     the shared render queue; tests pass one that holds each render
    ///     until they let it start and finish.
    ///   - cloud: The cloud services that get a book in a cloud library ready
    ///     to read (FR02). Nil uses the app's; tests pass fakes.
    init(
        book: Book,
        libraryViewModel: LibraryViewModel,
        settingsViewModel: SettingsViewModel,
        substitutionService: TextSubstitutionService? = nil,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        notificationCenter: NotificationCenter = .default,
        renderScheduler: (any SpeechRenderScheduling)? = nil,
        cloud: ReaderCloudServices? = nil
    ) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self.settingsViewModel = settingsViewModel
        // Resolved here rather than as default arguments, so the shared
        // main-actor services are read inside this main-actor initializer.
        self.substitutionService = substitutionService ?? .shared
        self.autoplayRequests = autoplayRequests ?? .shared
        self.notificationCenter = notificationCenter
        self.renderScheduler = renderScheduler ?? SpeechRenderCoordinator.shared
        self.cloudServices = cloud ?? .app
        self.bookmarks = book.bookmarks

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
        forwardSpeechState()

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

    /// Forward speechService @Published state to our own @Published properties
    /// so SwiftUI views that observe this ViewModel get updated.
    private func forwardSpeechState() {
        speechService.$isSpeaking
            .receive(on: DispatchQueue.main)
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

    /// Time from start of book to when a heading begins
    func timeToHeading(_ heading: Heading) -> TimeInterval {
        guard let content = content, content.totalCharacterCount > 0 else { return 0 }
        let globalOffset = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)

        if isAudioBook {
            return totalEstimatedTime
                * Double(globalOffset)
                / Double(content.totalCharacterCount)
        }

        guard speechService.wordsPerMinute > 0 else { return 0 }
        let fraction = Double(globalOffset) / Double(content.totalCharacterCount)
        return content.estimatedReadingTime(wpm: speechService.wordsPerMinute) * fraction
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
            onSkipForward: { [weak self] in self?.skipForward() },
            onSkipBackward: { [weak self] in self?.skipBackward() },
            // NowPlayingService needs to know whether playback is currently
            // running so it can correctly handle the Bluetooth-disconnect
            // suppress window: during that window, a spurious toggle command
            // is converted into a pause if playing, or ignored if already
            // paused (blocking macOS's spurious auto-resume bug).
            isCurrentlyPlaying: { [weak self] in
                guard let self = self else { return false }
                if self.isAudioBook {
                    return self.audioPlaybackService.isPlaying && !self.audioPlaybackService.isPaused
                }
                return self.speechService.isSpeaking && !self.speechService.isPaused
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
        let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow
        return WindowCommandRouting.shouldAccept(
            sourceWindow: sourceWindow,
            hostWindow: hostWindow,
            keyWindow: NSApp.keyWindow
        )
    }

    private func setupNotifications() {
        let nc = notificationCenter

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

        nc.publisher(for: .whereAmI)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.whereAmI()
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
        //   owned a timer — the user is restarting THAT timer.
        //   Falls back to the focused window when no prior timer
        //   exists yet (first-ever press).
        nc.publisher(for: .restartSleepTimer)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let bookToken = String(self.book.id.uuidString.prefix(8))
                let hasSourceWindow = notification.userInfo?["sourceWindow"] != nil
                let lastOwnerToken = self.sleepTimerService.lastOwnerID
                    .map { String($0.uuidString.prefix(8)) } ?? "none"
                SleepTimerService.log(
                    .event,
                    "RESTART_ROUTE_RECEIVED book=\(bookToken) sourceWindow=\(hasSourceWindow) "
                        + "lastOwner=\(lastOwnerToken)"
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
                    guard lastOwner == self.book.id else {
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
        /// An EPUB's own package metadata.
        let fileMetadata: EPUBMetadata?
        /// An audiobook's tags.
        let audioTags: AudioMetadata?
        /// Whether the index, or the version of the cache it was measured
        /// from, is new and must be saved with the book.
        let shouldPersistContentIndex: Bool
        /// The text cache format version the analysis vouches for.
        let cacheFormatVersion: String?
    }

    /// Start getting the book ready to read, showing Loading meanwhile.
    ///
    /// The book's library is checked first, off the main thread, since that
    /// reads file-system metadata (FR02). A book in a library that is not in
    /// a cloud location is read right away, in the same background step, as
    /// it always was. A book in a cloud location goes on through its cloud
    /// state (`continueOpening(in:found:)`): downloaded first when any of its
    /// files is only in the cloud, and then read without ever waiting on the
    /// network.
    func loadContent() {
        isLoading = true
        let bookCopy = book
        let storage = cloudServices.storage
        let package = BookPackage(bookCopy)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let location = storage.libraryLocation()
            if location.isCloud {
                let state = storage.state(of: package)
                DispatchQueue.main.async { [weak self] in
                    self?.continueOpening(in: location, found: state)
                }
                return
            }
            let result = Result { try ReaderViewModel.readContent(of: bookCopy) }
            DispatchQueue.main.async { [weak self] in
                self?.finishLoading(result, readFrom: bookCopy.filePath)
            }
        }
    }

    /// Reads `book`'s content, with the metadata its files hold: an EPUB's
    /// package metadata, or an audiobook's tags, from `tagsURL` when given
    /// (the same file in the book's working copy) and otherwise from the
    /// book's own file. Runs on a background queue.
    ///
    /// The book's own edits are laid over the metadata back on the main
    /// actor, from the reader's copy of the book as it is by then, so an
    /// edit the library makes while the book loads is shown too (TODO P10).
    nonisolated static func readContent(of book: Book, audioTagsFrom tagsURL: URL? = nil) throws -> LoadedContent {
        let url = book.bookFileURL
        let format = book.format
        let cacheOutdated = !format.isAudio
            && MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        let analysis = try BookContentAnalysisService.load(
            book: book,
            regenerateTextCache: cacheOutdated
        )

        var fileMetadata: EPUBMetadata?
        if format == .epub {
            fileMetadata = try? EPUBParser.readMetadata(url: url)
        }
        var audioTags: AudioMetadata?
        if format.isAudio {
            let tagged = tagsURL ?? url
            audioTags = (try? AsyncBridge.waitForResult { await AudioPlaybackService.extractFullMetadata(from: tagged) }) ?? AudioMetadata()
        }

        return LoadedContent(
            content: analysis.content,
            index: analysis.index,
            audioFiles: analysis.audioFilePaths,
            audioSegments: analysis.audioSegments,
            fileMetadata: fileMetadata,
            audioTags: audioTags,
            shouldPersistContentIndex: !analysis.usedPersistedIndex
                || book.contentIndexVersion != BookContentIndex.currentVersion
                || (!format.isAudio
                    && book.cacheFormatVersion != MarkdownCacheService.currentCacheVersion),
            cacheFormatVersion: analysis.cacheFormatVersion
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
    /// headings, its metadata, and its audio files, with the saved position
    /// kept within the book. Saves a new index, and starts playing for a
    /// finished book that continued to this one while it loaded.
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
        // Assigning content also publishes its headings.
        content = parsed
        epubMetadata = loaded.fileMetadata.map { book.mergingEditableEPUBMetadata($0) }
        audioMetadata = loaded.audioTags.map { book.mergingEditableAudioMetadata($0) }

        // Clamp saved reading position to valid range. The chapter
        // count can change if the book was re-imported or the cache
        // was regenerated with different parsing.
        if currentChapterIndex < 0 {
            currentChapterIndex = 0
            currentCharacterOffset = 0
        } else if currentChapterIndex >= parsed.chapters.count {
            currentChapterIndex = max(0, parsed.chapters.count - 1)
            currentCharacterOffset = 0
        }
        if currentChapterIndex < parsed.chapters.count {
            let chapterLen = parsed.chapters[currentChapterIndex].text.utf16Length
            if currentCharacterOffset < 0 || currentCharacterOffset > chapterLen {
                currentCharacterOffset = 0
            }
        }

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
        // A finished book may have continued to this one while
        // it loaded: start playing for it now.
        claimAutoplayRequest()
    }

    /// Shows why the book at `filePath` could not be read, in place of the
    /// reader.
    func showLoadFailure(_ error: Error, readFrom filePath: String) {
        // The library moved the book while it loaded, so the
        // files the load read may have gone from under it: load
        // it again from where the book is now (TODO P10).
        if book.filePath != filePath {
            loadContent()
            return
        }
        errorMessage = error.localizedDescription
        isLoading = false
        // A book that cannot load cannot play for a finished
        // book that continued to it; its error shows instead.
        discardAutoplayRequest()
    }

    // MARK: - Text Display Window

    /// Maximum number of characters to render in the SwiftUI Text view.
    /// Chapters under this limit are shown in full. Larger chapters show
    /// a sliding window around the current reading position so the UI
    /// stays responsive. The full text remains in memory for TTS.
    private static let maxDisplayChars = 20_000

    /// Return the text to display in the reader view. For small chapters,
    /// returns the full text. For large chapters, returns a window of text
    /// centred on the current character offset.
    private func makeVisibleTextWindow(_ fullText: String, centeredAt offset: Int) -> VisibleTextWindow {
        guard fullText.utf16Length > Self.maxDisplayChars else {
            return VisibleTextWindow(
                text: fullText,
                startOffset: 0,
                endOffset: fullText.utf16Length
            )
        }

        let halfWindow = Self.maxDisplayChars / 2
        let center = min(max(offset, halfWindow), fullText.utf16Length - halfWindow)
        let windowStart = max(center - halfWindow, 0)
        let windowEnd = min(center + halfWindow, fullText.utf16Length)

        let startIdx = fullText.index(atUTF16Offset: windowStart)
        let endIdx = fullText.index(atUTF16Offset: windowEnd)

        // Snap to paragraph boundaries so text doesn't start/end mid-word
        var adjustedStart = startIdx
        if windowStart > 0 {
            if let paraBreak = fullText.range(of: "\n\n", range: startIdx..<endIdx) {
                adjustedStart = paraBreak.upperBound
            }
        }
        var adjustedEnd = endIdx
        if windowEnd < fullText.utf16Length {
            if let paraBreak = fullText.range(of: "\n\n", options: .backwards, range: adjustedStart..<endIdx) {
                adjustedEnd = paraBreak.lowerBound
            }
        }

        return VisibleTextWindow(
            text: String(fullText[adjustedStart..<adjustedEnd]),
            startOffset: fullText.utf16Offset(of: adjustedStart),
            endOffset: fullText.utf16Offset(of: adjustedEnd)
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

        if pendingPlaybackUIRefresh != nil {
            schedulePlaybackUIRefresh()
        }
    }

    /// Update the displayed offset and cached reader text using a snapshot of
    /// the current playback position.
    private func refreshPlaybackUI(
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

        let shouldRefreshVisibleText = forceVisibleTextRefresh
            || shouldRefreshVisibleTextWindow(
                chapterIndex: resolvedChapterIndex,
                offset: resolvedOffset,
                chapterTextLength: resolvedChapterText.utf16Length
            )
        if shouldRefreshVisibleText {
            let window = makeVisibleTextWindow(resolvedChapterText, centeredAt: resolvedOffset)
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
            let window = makeVisibleTextWindow(resolvedChapterText, centeredAt: resolvedOffset)
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

    var canReleaseMediaControls: Bool {
        guard !mediaControlsReleased else { return false }
        if isAudioBook {
            return audioPlaybackService.isPlaying
                || audioPlaybackService.isPaused
                || isCurrentlyPlaying
                || isCurrentlyPaused
        }
        return speechService.isSpeaking
            || speechService.isPaused
            || isCurrentlyPlaying
            || isCurrentlyPaused
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
    }

    /// Builds the one canonical snapshot used by reader persistence and live
    /// library estimates, preventing formula inputs from drifting apart.
    private func makeCurrentReadingPosition() -> ReadingPosition {
        ReadingPosition(
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            globalCharacterOffset: currentGlobalOffset
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
        } else {
            libraryViewModel.updateLiveReadingPosition(bookID: book.id, position: position)
        }
        lastLivePositionPublish = now
    }

    /// Perform actor-isolated window teardown explicitly. Swift deinitializers
    /// are nonisolated, so shared UI services must be released while the view
    /// model is still on the main actor.
    func close() {
        guard !hasClosed else { return }
        hasClosed = true
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
        whereAmISynth.stopSpeaking(at: .immediate)
        nowPlayingService.clearNowPlaying()
        nowPlayingService.close()
        // Stop the shared sleep timer iff this book owned it. With the
        // singleton service, the timer would otherwise keep ticking
        // after our window closed — its callbacks captured `self`
        // weakly so they'd no-op, but the wall-clock countdown would
        // still run pointlessly until expiration. Owner check keeps us
        // from cancelling a timer Book B started after Book A closed.
        if sleepTimerService.ownerID == book.id {
            sleepTimerService.stop()
        }
        // Playback has stopped, so nothing reads the working copy any more
        // (FR02).
        removeWorkingCopy()
        libraryViewModel.bookUpdates.unwatch(book.id)
        libraryViewModel.unregisterOpenBook(book.id)
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
    /// the rendered speech of the chapter last played; the offset maps of
    /// its speech; the text window the reader showed; an audiobook's lists
    /// of files and clips; and the book's content, with its headings. An
    /// audiobook's player and its item went with `stop()`. What is left is
    /// the reader itself and its services, whose size does not depend on
    /// the book.
    private func releaseWhatGrowsWithTheBook() {
        cancellables.removeAll()
        discardLookAhead()
        speechService.audioEngine.discardRenderedAudio()
        currentTransformation = nil
        currentOffsetMap = nil
        pendingPlaybackUIRefresh = nil
        visibleTextWindowState = nil
        displayVisibleTextWindow = ""
        audioChapterFiles = []
        audioSegments = []
        // Also empties `headings`, which follow the content.
        content = nil
    }

}

// MARK: - Helpers

/// Helper delegate for the Where Am I synthesizer (separate from the book speech service)
///
/// `@unchecked Sendable`: its one property is a constant, and `onFinished`
/// runs only on the main queue, where the synthesizer's callback sends it.
final class WhereAmIDelegateHelper: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinished()
        }
    }
}
