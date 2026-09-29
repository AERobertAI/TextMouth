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
    @Published var errorMessage: String?
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
    let substitutionService = TextSubstitutionService.shared
    let readingStatsService = ReadingStatsService.shared
    let audioPlaybackService = AudioPlaybackService()

    /// Whether this book is an audio book (uses audio playback instead of TTS)
    var isAudioBook: Bool { book.format.isAudio }

    /// For multi-file audio books (ZIP import): file paths for each chapter
    var audioChapterFiles: [String] = []

    /// For segmented audio (DAISY): clip start/end times per chapter.
    /// When non-empty, each chapter's audio starts at segments[i].startTime
    /// and stops at segments[i].endTime within the corresponding file.
    var audioSegments: [AudioSegment] = []

    /// Audio playback speed (0.25 to 4.0, separate from WPM)
    @Published var audioSpeed: Double = 1.0

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
    /// route.
    var restartPlaybackBackendOnNextResume = false
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
    /// Pre-rendered audio engine for the next chapter (for seamless chapter transitions).
    /// Accessed from Navigation and Playback extensions.
    var nextChapterEngine: AudioEngineService?
    var nextChapterIndex: Int?
    /// Incremented on every navigation/skip action. The onUtteranceFinished callback
    /// checks this to ignore stale completions from a chapter that was playing before
    /// the user navigated away.
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

    init(book: Book, libraryViewModel: LibraryViewModel, settingsViewModel: SettingsViewModel) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self.settingsViewModel = settingsViewModel
        self.bookmarks = book.bookmarks

        libraryViewModel.registerOpenBook(book.id)

        // Restore reading position
        if let pos = book.readingPosition {
            currentChapterIndex = pos.chapterIndex
            currentCharacterOffset = pos.characterOffset
        }

        // Apply per-book voice/speed/pitch overrides
        if let localWPM = book.localWPM {
            speechService.setSpeedRealtime(localWPM)
        }
        if let localPitch = book.localPitch {
            speechService.setPitchRealtime(localPitch)
        }
        if let localVoiceID = book.localVoiceID,
           let voice = AVSpeechSynthesisVoice(identifier: localVoiceID) {
            speechService.currentVoice = voice
        }

        setupCallbacks()
        setupNotifications()
        forwardSpeechState()

        if isAudioBook {
            setupAudioCallbacks()
            if let localSpeed = book.localWPM {
                audioSpeed = AudioPlaybackService.clampedSpeed(localSpeed)
            }
        }

        loadContent()
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

        speechService.onUtteranceFinished = { [weak self] in
            guard let self = self else { return }
            let expectedGeneration = self.chapterPlaybackGeneration
            self.debugLog("onUtteranceFinished: chapter=\(self.currentChapterIndex) offset=\(self.currentCharacterOffset) gen=\(expectedGeneration)")

            // If a navigation happened since this chapter started playing,
            // ignore this stale completion — the new chapter is already set up.
            guard expectedGeneration == self.chapterPlaybackGeneration else {
                self.debugLog("ignoring stale onUtteranceFinished (gen \(expectedGeneration) != \(self.chapterPlaybackGeneration))")
                return
            }

            self.savePosition()
            self.sleepTimerService.notifyDocumentEnd(by: self.book.id)
            // Advance to next non-empty chapter if available
            if let content = self.content {
                var nextIndex = self.currentChapterIndex + 1
                while nextIndex < content.chapters.count && content.chapters[nextIndex].text.isEmpty {
                    nextIndex += 1
                }
                if nextIndex < content.chapters.count {
                    self.debugLog("advancing to chapter \(nextIndex) (from \(self.currentChapterIndex))")
                    self.currentChapterIndex = nextIndex
                    self.currentCharacterOffset = 0

                    // Increment generation for the new chapter
                    self.chapterPlaybackGeneration += 1

                    // Use pre-rendered engine if available for instant chapter start
                    if let preEngine = self.nextChapterEngine,
                       self.nextChapterIndex == nextIndex,
                       preEngine.hasRenderedAudio {
                        self.debugLog("using pre-rendered engine for chapter \(nextIndex)")
                        // Apply full text pipeline so offset map covers all stages
                        let (filteredText, filterMap) = self.filterSkippedSections(
                            chapterIndex: nextIndex, text: content.chapters[nextIndex].text)
                        let (pausedText, pauseMap) = self.applyPunctuationPauses(filteredText)
                        let transform = self.substitutionService.transform(pausedText)
                        self.currentTransformation = transform
                        self.currentOffsetMap = ComposedOffsetMap(stages: [filterMap, pauseMap] + transform.offsetMap.stages)
                        self.speechService.usePreRenderedEngine(preEngine, text: transform.modifiedText)
                        self.nextChapterEngine = nil
                        self.nextChapterIndex = nil
                        // Pre-render the chapter after that
                        self.preRenderNextChapter()
                    } else {
                        self.speakCurrentChapter()
                    }
                } else {
                    self.debugLog("no more chapters, book ended")
                    self.readingStatsService.endSession(bookID: self.book.id)
                    self.handleEndOfBook()
                }
            }
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
        let nc = NotificationCenter.default

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
                SleepTimerService.appendDiagnosticLog(
                    "RESTART_ROUTE_RECEIVED book=\(bookToken) sourceWindow=\(hasSourceWindow) "
                        + "lastOwner=\(lastOwnerToken)"
                )
                if notification.userInfo?["sourceWindow"] != nil {
                    guard self.isTargetedNotification(notification) else {
                        SleepTimerService.appendDiagnosticLog(
                            "RESTART_ROUTE_REJECTED book=\(bookToken) reason=source-window-mismatch"
                        )
                        return
                    }
                } else if let lastOwner = self.sleepTimerService.lastOwnerID {
                    guard lastOwner == self.book.id else {
                        SleepTimerService.appendDiagnosticLog(
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
                        SleepTimerService.appendDiagnosticLog(
                            "RESTART_ROUTE_REJECTED book=\(bookToken) reason=no-focused-window"
                        )
                        return
                    }
                }
                SleepTimerService.appendDiagnosticLog(
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
                if let localWPM = self.book.localWPM {
                    self.speechService.setSpeedRealtime(localWPM)
                }
                if let localPitch = self.book.localPitch {
                    self.speechService.setPitchRealtime(localPitch)
                }
                if let localVoiceID = self.book.localVoiceID,
                   let voice = AVSpeechSynthesisVoice(identifier: localVoiceID) {
                    self.speechService.currentVoice = voice
                }
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
    }

    // MARK: - Content Loading

    private func loadContent() {
        isLoading = true
        let filePath = book.filePath
        let format = book.format
        let bookCopy = book
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = URL(fileURLWithPath: filePath)
                let cacheOutdated = !format.isAudio
                    && MarkdownCacheService.isCacheOutdated(stored: bookCopy.cacheFormatVersion)
                let analysis = try BookContentAnalysisService.load(
                    book: bookCopy,
                    regenerateTextCache: cacheOutdated
                )
                let parsed = analysis.content
                let audioFiles = analysis.audioFilePaths
                let audioSegments = analysis.audioSegments

                // Load EPUB metadata if applicable
                var metadata: EPUBMetadata?
                if format == .epub {
                    if let extracted = try? EPUBParser.readMetadata(url: url) {
                        metadata = bookCopy.mergingEditableEPUBMetadata(extracted)
                    }
                }

                // Load audio metadata from file tags, then overlay any user-edited fields
                // stored in the Book model so previous edits are preserved
                var audioMeta: AudioMetadata?
                if format.isAudio {
                    var extracted = (try? waitForAsync { await AudioPlaybackService.extractFullMetadata(from: url) }) ?? AudioMetadata()
                    // Use the book's stored title/author (which may have been user-edited)
                    extracted.title = bookCopy.title
                    extracted.artist = bookCopy.author
                    // Overlay stored audio-specific fields if the user previously edited them
                    if let album = bookCopy.audioAlbum { extracted.album = album }
                    if let genre = bookCopy.audioGenre { extracted.genre = genre }
                    if let year = bookCopy.audioYear { extracted.year = year }
                    audioMeta = extracted
                }

                let loadedAudioFiles = audioFiles
                let loadedAudioSegments = audioSegments
                let loadedMetadata = metadata
                let loadedAudioMetadata = audioMeta
                let loadedContentIndex = analysis.index
                let shouldPersistContentIndex = !analysis.usedPersistedIndex
                    || bookCopy.contentIndexVersion != BookContentIndex.currentVersion
                    || (!format.isAudio
                        && bookCopy.cacheFormatVersion != MarkdownCacheService.currentCacheVersion)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.hasClosed else { return }
                    if let audioFiles = loadedAudioFiles {
                        self.audioChapterFiles = audioFiles
                    }
                    if let segs = loadedAudioSegments {
                        self.audioSegments = segs
                    }
                    // Assigning content also publishes its headings.
                    self.content = parsed
                    self.epubMetadata = loadedMetadata
                    self.audioMetadata = loadedAudioMetadata

                    // Clamp saved reading position to valid range. The chapter
                    // count can change if the book was re-imported or the cache
                    // was regenerated with different parsing.
                    if self.currentChapterIndex < 0 {
                        self.currentChapterIndex = 0
                        self.currentCharacterOffset = 0
                    } else if self.currentChapterIndex >= parsed.chapters.count {
                        self.currentChapterIndex = max(0, parsed.chapters.count - 1)
                        self.currentCharacterOffset = 0
                    }
                    if self.currentChapterIndex < parsed.chapters.count {
                        let chapterLen = parsed.chapters[self.currentChapterIndex].text.utf16Length
                        if self.currentCharacterOffset < 0 || self.currentCharacterOffset > chapterLen {
                            self.currentCharacterOffset = 0
                        }
                    }

                    self.isLoading = false

                    if shouldPersistContentIndex {
                        self.libraryViewModel.updateContentIndex(
                            bookID: self.book.id,
                            index: loadedContentIndex,
                            cacheFormatVersion: analysis.cacheFormatVersion
                        )
                    }

                    // Save position with global offset now that we have chapter data
                    self.savePosition()
                    self.refreshPlaybackUI()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.hasClosed else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
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

    // MARK: - Debug Logging

    /// Append a timestamped message to the debug log file.
    /// Dispatched to a background queue so FileHandle I/O doesn't
    /// block the main thread during playback callbacks.
    func debugLog(_ msg: String) {
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: msg)
    }

    /// Perform actor-isolated window teardown explicitly. Swift deinitializers
    /// are nonisolated, so shared UI services must be released while the view
    /// model is still on the main actor.
    func close() {
        guard !hasClosed else { return }
        hasClosed = true
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
        libraryViewModel.unregisterOpenBook(book.id)
    }

}

// MARK: - Helpers

/// Bridge async code to sync context
private func waitForAsync<T>(_ block: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ReaderAsyncResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.store(.success(try await block()))
        } catch let e {
            box.store(.failure(e))
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.value else {
        throw NSError(domain: "TextMouth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Async operation returned no result"])
    }
    return try result.get()
}

private final class ReaderAsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}

/// Helper delegate for the Where Am I synthesizer (separate from the book speech service)
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
