import SwiftUI
import Combine
import AppKit
import AVFoundation
import os.log

/// Manages the state for reading a single book
class ReaderViewModel: ObservableObject {
    @Published var book: Book
    let libraryViewModel: LibraryViewModel
    let settingsViewModel: SettingsViewModel
    var soundEffectService: SoundEffectService?

    @Published var content: DocumentContent?
    @Published var currentChapterIndex = 0
    @Published var currentCharacterOffset = 0
    @Published var isLoading = true
    @Published var errorMessage: String?
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
    let sleepTimerService = SleepTimerService()
    let nowPlayingService = NowPlayingService()
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
    /// Track when "Where Am I?" was last triggered for brief->full escalation.
    /// Accessed from WhereAmI extension.
    var lastWhereAmITime: Date = .distantPast

    /// Base offset for word-spoken callback tracking
    var utteranceBaseOffset: Int = 0
    private var cancellables = Set<AnyCancellable>()
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

    /// For audio books, 10 characters = 1 second of audio.
    /// All time calculations use this constant to convert character offsets to/from seconds.
    static let audioCharsPerSecond: Double = 10.0

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
                audioSpeed = localSpeed
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
    }

    // MARK: - Time & Progress Calculations

    var totalWordCount: Int {
        content?.totalWordCount ?? 0
    }

    var totalEstimatedTime: TimeInterval {
        if isAudioBook {
            // Audio book: character count / 10 = total seconds, adjusted by playback speed
            let totalChars = Double(content?.totalCharacterCount ?? 0)
            return totalChars / Self.audioCharsPerSecond / audioSpeed
        }
        return content?.estimatedReadingTime(wpm: speechService.wordsPerMinute) ?? 0
    }

    /// Total duration at 1x speed (not adjusted for playback speed), for progress displays
    private var totalAudioDuration: TimeInterval {
        Double(content?.totalCharacterCount ?? 0) / Self.audioCharsPerSecond
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
        if isAudioBook {
            let totalChars = Double(content?.totalCharacterCount ?? 0)
            guard totalChars > 0 else { return 0 }
            let remainingChars = Double(max(Int(totalChars) - currentGlobalOffset, 0))
            return remainingChars / Self.audioCharsPerSecond / audioSpeed
        }
        return content?.estimatedTimeRemaining(fromGlobalOffset: currentGlobalOffset, wpm: speechService.wordsPerMinute) ?? 0
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
            return Double(charCount) / Self.audioCharsPerSecond / audioSpeed
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
            return Double(globalOffset) / Self.audioCharsPerSecond / audioSpeed
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
            // Map from modified-text offset back to original-text offset
            if let transform = self.currentTransformation, transform.hasChanges {
                self.currentCharacterOffset = transform.toOriginalOffset(range.location)
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
            self.sleepTimerService.notifyDocumentEnd()
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
                        let transform = self.substitutionService.transform(content.chapters[nextIndex].text)
                        self.currentTransformation = transform
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
                    self.readingStatsService.endSession()
                    self.handleEndOfBook()
                }
            }
        }

        sleepTimerService.onTimerExpired = { [weak self] in
            guard let self = self else { return }
            if self.isAudioBook {
                self.audioPlaybackService.restoreVolume()
            } else {
                self.speechService.audioEngine.restoreVolume()
            }
            self.pause()
            self.announceToVoiceOver("Sleep timer expired. Playback paused.")
        }

        sleepTimerService.onFadeStep = { [weak self] volume in
            guard let self = self else { return }
            if self.isAudioBook {
                self.audioPlaybackService.setVolume(volume)
            } else {
                self.speechService.audioEngine.setVolume(volume)
            }
        }

        // Apply fade-out duration from settings
        sleepTimerService.fadeOutDuration = settingsViewModel.sleepFadeOutDuration

        nowPlayingService.setup(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSkipForward: { [weak self] in self?.skipForward() },
            onSkipBackward: { [weak self] in self?.skipBackward() }
        )
    }

    /// Check whether a notification should be handled by this reader instance.
    /// - Keyboard shortcuts include sourceWindow: only respond if it matches hostWindow.
    /// - Menu commands have no sourceWindow: only respond if this reader's window is key.
    private func isTargetedNotification(_ notification: Notification) -> Bool {
        if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
            // Keyboard shortcut — only the window that had focus should respond
            return sourceWindow === hostWindow
        }
        // Menu command — only the key (focused) window's reader should respond
        guard let hostWindow = hostWindow else { return true }
        return hostWindow.isKeyWindow
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default

        nc.publisher(for: .togglePlayback)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.togglePlayPause()
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

        nc.publisher(for: .increaseSpeed)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.adjustSpeed(delta: 25)
            }
            .store(in: &cancellables)

        nc.publisher(for: .decreaseSpeed)
            .sink { [weak self] notification in
                guard let self = self, self.isTargetedNotification(notification) else { return }
                self.adjustSpeed(delta: -25)
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
                self.addBookmarkAtCurrentPosition()
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

        // Settings changes apply to all reader windows (not window-specific)
        nc.publisher(for: .speechSettingsChanged)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.sleepTimerService.fadeOutDuration = self.settingsViewModel.sleepFadeOutDuration
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
                let parsed: DocumentContent
                var audioFiles: [String]?
                var audioSegments: [AudioSegment]?

                if format.isAudio {
                    // Check if this is a multi-file audio book (directory of audio files)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
                        guard self != nil else { return }
                        let result = try waitForAsync { try await AudioBookParser.parseDirectory(url: url) }
                        parsed = result.content
                        audioFiles = result.filePaths
                        audioSegments = result.segments
                    } else {
                        parsed = try BookParser.parse(url: url, format: format)
                    }
                } else {
                    // Generate cache if missing, then always load from it so
                    // reading positions are consistent across sessions
                    if !MarkdownCacheService.cacheExists(for: bookCopy) {
                        MarkdownCacheService.generateCache(for: bookCopy)
                    }
                    if MarkdownCacheService.cacheExists(for: bookCopy) {
                        parsed = try MarkdownCacheService.loadFromCache(for: bookCopy)
                    } else {
                        // Cache generation failed — fall back to original parser
                        parsed = try BookParser.parse(url: url, format: format)
                    }
                }

                // Load EPUB metadata if applicable
                var metadata: EPUBMetadata?
                if format == .epub {
                    metadata = try? EPUBParser.readMetadata(url: url)
                }

                // Load audio metadata from file tags, then overlay any user-edited fields
                // stored in the Book model so previous edits are preserved
                var audioMeta: AudioMetadata?
                if format.isAudio {
                    var extracted = (try? waitForAsync { await AudioPlaybackService.extractFullMetadata(from: url) }) ?? AudioMetadata()
                    // Use the book's stored title/author (which may have been user-edited)
                    extracted.title = self?.book.title ?? extracted.title
                    extracted.artist = self?.book.author ?? extracted.artist
                    // Overlay stored audio-specific fields if the user previously edited them
                    if let album = self?.book.audioAlbum { extracted.album = album }
                    if let genre = self?.book.audioGenre { extracted.genre = genre }
                    if let year = self?.book.audioYear { extracted.year = year }
                    audioMeta = extracted
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let audioFiles = audioFiles {
                        self.audioChapterFiles = audioFiles
                    }
                    if let segs = audioSegments {
                        self.audioSegments = segs
                    }
                    self.content = parsed
                    self.headings = parsed.allHeadings
                    self.epubMetadata = metadata
                    self.audioMetadata = audioMeta
                    self.isLoading = false

                    // Save word/char counts for library time estimation
                    self.libraryViewModel.updateWordCounts(
                        bookID: self.book.id,
                        wordCount: parsed.totalWordCount,
                        charCount: parsed.totalCharacterCount
                    )

                    // For audio books, save the total duration derived from character count
                    if self.isAudioBook {
                        let duration = Double(parsed.totalCharacterCount) / Self.audioCharsPerSecond
                        self.libraryViewModel.updateAudioDuration(bookID: self.book.id, duration: duration)
                    }

                    // Save position with global offset now that we have chapter data
                    self.savePosition()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                }
            }
        }
    }

    // MARK: - Position Saving

    /// Persist the current reading position to the library
    func savePosition() {
        let position = ReadingPosition(
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            globalCharacterOffset: currentGlobalOffset
        )
        libraryViewModel.updateReadingPosition(bookID: book.id, position: position)
    }

    // MARK: - Debug Logging

    /// Append a timestamped message to the debug log file
    func debugLog(_ msg: String) {
        let logPath = TextMouthPaths.debugLogFile.path
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    deinit {
        speechService.stop()
        audioPlaybackService.stop()
        whereAmISynth.stopSpeaking(at: .immediate)
        nowPlayingService.clearNowPlaying()
        libraryViewModel.unregisterOpenBook(book.id)
    }
}

// MARK: - Helpers

/// Bridge async code to sync context
private func waitForAsync<T>(_ block: @escaping () async throws -> T) throws -> T {
    var result: T?
    var error: Error?
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            result = try await block()
        } catch let e {
            error = e
        }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = error { throw error }
    guard let value = result else {
        throw NSError(domain: "TextMouth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Async operation returned no result"])
    }
    return value
}

/// Helper delegate for the Where Am I synthesizer (separate from the book speech service)
class WhereAmIDelegateHelper: NSObject, AVSpeechSynthesizerDelegate {
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
