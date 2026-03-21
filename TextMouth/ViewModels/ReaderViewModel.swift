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

    /// Audio playback speed (0.25 to 4.0, separate from WPM)
    @Published var audioSpeed: Double = 1.0

    /// Current text transformation for mapping modified↔original offsets
    private var currentTransformation: TextTransformation?

    /// Saved position before heading/bookmark navigation (for "go back to where I was")
    @Published var hasSavedPosition = false
    private var savedChapterIndex: Int = 0
    private var savedCharacterOffset: Int = 0

    /// The NSWindow hosting this reader. Used to check if this is the focused window
    /// before responding to keyboard shortcut notifications (prevents K from activating
    /// playback in ALL open book windows at once).
    weak var hostWindow: NSWindow?

    /// Separate synthesizer for "Where Am I?" announcements (not the book reader)
    private let whereAmISynth = AVSpeechSynthesizer()
    /// Whether playback was active before "Where Am I?" interrupted it
    private var wasPlayingBeforeWhereAmI = false
    /// Track when "Where Am I?" was last triggered for brief→full escalation
    private var lastWhereAmITime: Date = .distantPast

    private var utteranceBaseOffset: Int = 0
    private var cancellables = Set<AnyCancellable>()
    /// Debounce skip calls — ignore rapid-fire duplicates
    private var lastSkipTime: Date = .distantPast
    /// Pre-rendered audio engine for the next chapter (for seamless chapter transitions)
    private var nextChapterEngine: AudioEngineService?
    private var nextChapterIndex: Int?
    /// Incremented on every navigation/skip action. The onUtteranceFinished callback
    /// checks this to ignore stale completions from a chapter that was playing before
    /// the user navigated away.
    private var chapterPlaybackGeneration: Int = 0

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

        // Apply per-book voice/speed overrides
        if let localWPM = book.localWPM {
            speechService.setSpeedRealtime(localWPM)
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

    /// For audio books, 10 characters = 1 second of audio.
    /// All time calculations use this constant to convert character offsets to/from seconds.
    private static let audioCharsPerSecond: Double = 10.0

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
                if let localWPM = self.book.localWPM {
                    self.speechService.setSpeedRealtime(localWPM)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = URL(fileURLWithPath: filePath)
                let parsed: DocumentContent
                var audioFiles: [String]?

                if format.isAudio {
                    // Check if this is a multi-file audio book (directory of audio files)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
                        guard self != nil else { return }
                        let result = try waitForAsync { try await AudioBookParser.parseDirectory(url: url) }
                        parsed = result.content
                        audioFiles = result.filePaths
                    } else {
                        parsed = try BookParser.parse(url: url, format: format)
                    }
                } else {
                    parsed = try BookParser.parse(url: url, format: format)
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

    // MARK: - Playback

    func play() {
        // Don't start playback while Where Am I is speaking
        if isWhereAmISpeaking { return }
        soundEffectService?.play(for: .play)
        recordPlaybackStarted()
        readingStatsService.startSession(bookID: book.id)
        if isAudioBook {
            playAudioChapter()
        } else {
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }
    }

    func pause() {
        soundEffectService?.play(for: .pause)
        if sleepTimerService.isFadingOut {
            sleepTimerService.stop()
            if isAudioBook { audioPlaybackService.restoreVolume() }
            else { speechService.audioEngine.restoreVolume() }
        }
        if isAudioBook {
            audioPlaybackService.pause()
            isCurrentlyPlaying = true // still "playing" but paused
            isCurrentlyPaused = true
        } else {
            speechService.pause()
        }
        readingStatsService.endSession()
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: false
        )
        recordPlaybackStopped()
        savePosition()
    }

    func togglePlayPause() {
        // If Where Am I is speaking, stop the announcement and resume/don't resume book.
        // Don't allow toggling playback while Where Am I is active — it would cause
        // both the book and the announcement to play simultaneously.
        if isWhereAmISpeaking {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            // Don't resume book — user explicitly pressed play/pause, not "dismiss Where Am I"
            wasPlayingBeforeWhereAmI = false
            return
        }

        if isAudioBook {
            if audioPlaybackService.isPaused {
                soundEffectService?.play(for: .play)
                recordPlaybackStarted()
                readingStatsService.startSession(bookID: book.id)
                audioPlaybackService.resume()
                isCurrentlyPaused = false
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            } else if audioPlaybackService.isPlaying {
                pause()
            } else {
                play()
            }
            return
        }

        debugLog("togglePlayPause called, isSpeaking=\(speechService.isSpeaking) isPaused=\(speechService.isPaused)")
        if speechService.isPaused {
            soundEffectService?.play(for: .play)
            applyRewindOnResume()
            recordPlaybackStarted()
            readingStatsService.startSession(bookID: book.id)
            speechService.resume()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        } else if speechService.isSpeaking {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        if sleepTimerService.isFadingOut {
            sleepTimerService.stop()
        }
        if isAudioBook {
            audioPlaybackService.restoreVolume()
            audioPlaybackService.stop()
            isCurrentlyPlaying = false
            isCurrentlyPaused = false
        } else {
            speechService.audioEngine.restoreVolume()
            speechService.stop()
        }
        readingStatsService.endSession()
        nowPlayingService.clearNowPlaying()
        recordPlaybackStopped()
        savePosition()
    }

    private func speakCurrentChapter() {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        // Skip empty chapters
        var idx = currentChapterIndex
        while idx < content.chapters.count && content.chapters[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idx += 1
        }
        if idx != currentChapterIndex {
            currentChapterIndex = idx
            currentCharacterOffset = 0
        }
        guard idx < content.chapters.count else { return }

        let chapter = content.chapters[currentChapterIndex]
        guard !chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        debugLog("speakCurrentChapter: chapter=\(currentChapterIndex) offset=\(currentCharacterOffset) gen=\(chapterPlaybackGeneration)")

        // Filter out skipped sections, apply punctuation pauses, then text substitutions
        let filteredText = filterSkippedSections(chapterIndex: currentChapterIndex, text: chapter.text)
        let pausedText = applyPunctuationPauses(filteredText)
        let transformation = substitutionService.transform(pausedText)
        currentTransformation = transformation
        let speakText = transformation.modifiedText
        let speakOffset = transformation.toModifiedOffset(currentCharacterOffset)

        // Start playback from the current offset.
        utteranceBaseOffset = 0
        speechService.speak(speakText, fromCharOffset: speakOffset)

        // Pre-render the next chapter so it can start instantly when this one ends
        preRenderNextChapter()
    }

    /// Pre-render the next chapter's audio in background so chapter transitions are instant
    private func preRenderNextChapter() {
        guard let content = content else { return }
        var nextIdx = currentChapterIndex + 1
        while nextIdx < content.chapters.count && content.chapters[nextIdx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextIdx += 1
        }
        guard nextIdx < content.chapters.count else {
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil
            return
        }

        // Cancel any stale pre-render before starting a new one
        nextChapterEngine?.cancelRender()

        let engine = AudioEngineService()
        let rawText = content.chapters[nextIdx].text
        let chapterText = substitutionService.transform(rawText).modifiedText
        nextChapterIndex = nextIdx

        engine.render(text: chapterText, voice: speechService.currentVoice, wpm: speechService.wordsPerMinute) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.nextChapterEngine = engine
                self.debugLog("preRender: chapter \(nextIdx) ready (\(chapterText.count) chars)")
            }
        }
    }

    // MARK: - Navigation

    private func debugLog(_ msg: String) {
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

    func skipForward(useShiftUnit: Bool = false) {
        // Debounce: ignore if called again within 0.3 seconds
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.3 else { return }
        lastSkipTime = now
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipForward)
        let unit = useShiftUnit ? settingsViewModel.shiftSkipForwardUnit : settingsViewModel.skipForwardUnit
        debugLog("skipForward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: true)
    }

    func skipBackward(useShiftUnit: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.3 else { return }
        lastSkipTime = now
        cancelWhereAmIIfActive()
        soundEffectService?.play(for: .skipBackward)
        let unit = useShiftUnit ? settingsViewModel.shiftSkipBackwardUnit : settingsViewModel.skipBackwardUnit
        debugLog("skipBackward called, unit=\(unit.rawValue) shift=\(useShiftUnit)")
        performSkip(unit: unit, forward: false)
    }

    private func performSkip(unit: SkipUnit, forward: Bool) {
        debugLog("performSkip unit=\(unit.rawValue) forward=\(forward) wpm=\(speechService.wordsPerMinute)")
        switch unit {
        case .heading:
            if forward { nextHeading() } else { previousHeading() }
        case .subheading:
            // Find next heading of level >= 2
            if forward { nextSubheading() } else { previousSubheading() }
        case .bookmark:
            if forward { goToNextBookmark() } else { goToPreviousBookmark() }
        default:
            // Time-based skip
            if isAudioBook, let seconds = unit.seconds {
                // For audio: convert seconds directly to character offset (10 chars = 1 second)
                let charDelta = Int(Double(seconds) * Self.audioCharsPerSecond)
                skipCharacters(count: forward ? charDelta : -charDelta)
            } else if let wordCount = unit.wordCount(wpm: speechService.wordsPerMinute) {
                skipWords(count: forward ? wordCount : -wordCount)
            }
        }
    }

    private func nextSubheading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings
        if let nextIndex = allHeadings.firstIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex > currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
            )
        }) {
            let heading = allHeadings[nextIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary()
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    private func previousSubheading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings
        if let prevIndex = allHeadings.lastIndex(where: {
            $0.level >= 2 && (
                $0.chapterIndex < currentChapterIndex ||
                ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset - 10)
            )
        }) {
            let heading = allHeadings[prevIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary()
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    private func skipWords(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused
        let charDelta = count * 5  // ~5 chars per word average
        let chapterLen = content.chapters[currentChapterIndex].text.count

        debugLog("skipWords count=\(count) charDelta=\(charDelta) currentOffset=\(currentCharacterOffset) chapterLen=\(chapterLen) chapter=\(currentChapterIndex)")

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + charDelta

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.count
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.count {
                charOffset -= content.chapters[chapIdx].text.count
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.count - 1)
            }
        }

        // Snap to word boundary
        let text = content.chapters[chapIdx].text
        if charOffset > 0 && charOffset < text.count {
            let targetIndex = text.index(text.startIndex, offsetBy: charOffset)
            var wordStart = targetIndex
            while wordStart > text.startIndex && !text[text.index(before: wordStart)].isWhitespace {
                wordStart = text.index(before: wordStart)
            }
            charOffset = text.distance(from: text.startIndex, to: wordStart)
        }

        let sameChapter = (chapIdx == currentChapterIndex)

        debugLog("skipWords result -> chapter=\(chapIdx) offset=\(charOffset) sameChapter=\(sameChapter)")

        if sameChapter {
            // Same chapter: seek without re-rendering.
            // If engine has rendered audio, this is an instant buffer seek.
            // If still in direct mode, this restarts direct speech from the new offset
            // without cancelling the in-progress engine render.
            currentCharacterOffset = charOffset
            speechService.seek(toCharOffset: charOffset)
        } else {
            // Different chapter — invalidate stale callbacks before changing state
            chapterPlaybackGeneration += 1
            // Cancel stale pre-rendered chapter
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil

            speechService.stop()

            // Now safe to update chapter/offset — no stale callback can overwrite
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset

            if wasPlaying {
                speakCurrentChapter()
            }
        }

        if wasPlaying {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }

        savePosition()
    }

    /// Skip by a specific number of characters (used for audio book time-based skipping).
    /// For audio books, 10 characters = 1 second.
    private func skipCharacters(count: Int) {
        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let wasPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused

        var chapIdx = currentChapterIndex
        var charOffset = currentCharacterOffset + count

        // Handle cross-chapter navigation
        if charOffset < 0 {
            while charOffset < 0 && chapIdx > 0 {
                chapIdx -= 1
                charOffset += content.chapters[chapIdx].text.count
            }
            charOffset = max(0, charOffset)
        } else {
            while chapIdx < content.chapters.count && charOffset >= content.chapters[chapIdx].text.count {
                charOffset -= content.chapters[chapIdx].text.count
                chapIdx += 1
            }
            if chapIdx >= content.chapters.count {
                chapIdx = content.chapters.count - 1
                charOffset = max(0, content.chapters[chapIdx].text.count - 1)
            }
        }

        if chapIdx != currentChapterIndex {
            audioPlaybackService.stop()
            currentChapterIndex = chapIdx
            currentCharacterOffset = charOffset
            if wasPlaying {
                playAudioChapter()
            }
        } else {
            currentCharacterOffset = charOffset
            let timeOffset = Double(charOffset) / Self.audioCharsPerSecond
            audioPlaybackService.seek(to: timeOffset)
        }

        savePosition()
    }

    func nextHeading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings

        if let nextIndex = allHeadings.firstIndex(where: {
            $0.chapterIndex > currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
        }) {
            let heading = allHeadings[nextIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary()
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    func previousHeading() {
        guard let content = content else { return }
        let allHeadings = content.allHeadings

        if let prevIndex = allHeadings.lastIndex(where: {
            $0.chapterIndex < currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset - 10)
        }) {
            let heading = allHeadings[prevIndex]
            navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
            sleepTimerService.notifyHeadingBoundary()
            announceToVoiceOver("Heading: \(heading.text)")
        }
    }

    func navigateToHeading(_ heading: Heading) {
        savePositionForReturn()
        navigateTo(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
        autoPlayIfEnabled()
    }

    func navigateTo(chapterIndex: Int, characterOffset: Int) {
        if isAudioBook {
            let wasPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
            if chapterIndex != currentChapterIndex {
                audioPlaybackService.stop()
                currentChapterIndex = chapterIndex
                currentCharacterOffset = characterOffset
                if wasPlaying {
                    playAudioChapter()
                }
            } else {
                currentCharacterOffset = characterOffset
                let timeOffset = Double(characterOffset) / 10.0
                audioPlaybackService.seek(to: timeOffset)
            }
            savePosition()
            return
        }

        let wasPlaying = speechService.isSpeaking && !speechService.isPaused

        if chapterIndex == currentChapterIndex && wasPlaying {
            // Same chapter: instant seek, no re-rendering
            currentCharacterOffset = characterOffset
            speechService.seek(toCharOffset: characterOffset)
        } else {
            // Different chapter — invalidate stale callbacks first
            chapterPlaybackGeneration += 1
            nextChapterEngine?.cancelRender()
            nextChapterEngine = nil
            nextChapterIndex = nil

            speechService.stop()
            currentChapterIndex = chapterIndex
            currentCharacterOffset = characterOffset
            if wasPlaying {
                speakCurrentChapter()
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
        }

        savePosition()
    }

    // MARK: - Speed & Voice

    func adjustSpeed(delta: Double) {
        if isAudioBook {
            adjustAudioSpeed(delta: delta)
            return
        }
        let newWPM = max(speechService.minimumWPM, min(speechService.wordsPerMinute + delta, speechService.maximumWPM))
        speechService.setSpeedRealtime(newWPM)
        book.localWPM = speechService.wordsPerMinute
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: book.localVoiceID,
            wpm: book.localWPM
        )
        announceToVoiceOver("\(Int(speechService.wordsPerMinute)) words per minute")
    }

    /// Set voice for this book only
    func setLocalVoice(_ voice: AVSpeechSynthesisVoice) {
        speechService.currentVoice = voice
        book.localVoiceID = voice.identifier
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: book.localVoiceID,
            wpm: book.localWPM
        )
        announceToVoiceOver("Voice changed to \(voice.name)")
    }

    /// Copy this book's local voice and speed to the global settings
    func saveSettingsToGlobal() {
        if let localWPM = book.localWPM {
            settingsViewModel.wordsPerMinute = localWPM
        }
        if let localVoiceID = book.localVoiceID {
            settingsViewModel.selectedVoiceID = localVoiceID
        }
        announceToVoiceOver("Settings saved to global defaults")
    }

    /// Reset this book to use global voice and speed settings
    func resetToGlobalSettings() {
        book.localVoiceID = nil
        book.localWPM = nil
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: nil,
            wpm: nil
        )
        // Apply global settings
        speechService.setSpeedRealtime(settingsViewModel.wordsPerMinute)
        if let voice = settingsViewModel.selectedVoice {
            speechService.currentVoice = voice
        }
        announceToVoiceOver("Using global voice and speed settings")
    }

    /// Whether this book has local voice/speed overrides
    var hasLocalSettings: Bool {
        book.localVoiceID != nil || book.localWPM != nil
    }

    // MARK: - Skip Sections

    /// Set of heading IDs marked as "skip" for this book
    var skippedHeadingIDs: Set<String> {
        Set(book.skippedHeadingIDs ?? [])
    }

    func isHeadingSkipped(_ heading: Heading) -> Bool {
        skippedHeadingIDs.contains(heading.id)
    }

    func toggleHeadingSkip(_ heading: Heading) {
        var ids = book.skippedHeadingIDs ?? []
        if ids.contains(heading.id) {
            ids.removeAll { $0 == heading.id }
            announceToVoiceOver("Section included: \(heading.text)")
        } else {
            ids.append(heading.id)
            announceToVoiceOver("Section skipped: \(heading.text)")
        }
        book.skippedHeadingIDs = ids
        libraryViewModel.updateSkippedHeadings(bookID: book.id, skippedIDs: ids)
    }

    /// Remove text under skipped headings from a chapter's text.
    /// Returns the filtered text for TTS.
    func filterSkippedSections(chapterIndex: Int, text: String) -> String {
        guard let content = content else { return text }
        let skipped = skippedHeadingIDs
        guard !skipped.isEmpty else { return text }

        let chapterHeadings = content.allHeadings.filter { $0.chapterIndex == chapterIndex }
        guard !chapterHeadings.isEmpty else { return text }

        // Build ranges to exclude
        var excludeRanges: [Range<Int>] = []
        for (i, heading) in chapterHeadings.enumerated() {
            guard skipped.contains(heading.id) else { continue }
            let start = heading.characterOffset
            let end: Int
            if i + 1 < chapterHeadings.count {
                end = chapterHeadings[i + 1].characterOffset
            } else {
                end = text.count
            }
            excludeRanges.append(start..<end)
        }

        guard !excludeRanges.isEmpty else { return text }

        // Build filtered text by including only non-excluded ranges
        var result = ""
        var pos = 0
        for range in excludeRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if pos < range.lowerBound {
                let startIdx = text.index(text.startIndex, offsetBy: pos)
                let endIdx = text.index(text.startIndex, offsetBy: min(range.lowerBound, text.count))
                result += text[startIdx..<endIdx]
            }
            pos = range.upperBound
        }
        if pos < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: pos)
            result += text[startIdx...]
        }
        return result
    }

    // MARK: - Bookmarks

    func addBookmarkAtCurrentPosition(label: String = "") {
        libraryViewModel.addBookmark(
            bookID: book.id,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            label: label
        )
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        announceToVoiceOver("Bookmark \(bookmarks.count) added")
    }

    func updateBookmarkLabel(_ bookmark: Bookmark, label: String) {
        libraryViewModel.updateBookmarkLabel(bookID: book.id, bookmarkID: bookmark.id, label: label)
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
    }

    func goToNextBookmark() {
        let sorted = bookmarks.sorted { $0.number < $1.number }
        if let next = sorted.first(where: {
            $0.chapterIndex > currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
        }) {
            navigateTo(chapterIndex: next.chapterIndex, characterOffset: next.characterOffset)
            announceToVoiceOver("Bookmark \(next.number)")
        }
    }

    func goToPreviousBookmark() {
        let sorted = bookmarks.sorted { $0.number > $1.number }
        if let prev = sorted.first(where: {
            $0.chapterIndex < currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset)
        }) {
            navigateTo(chapterIndex: prev.chapterIndex, characterOffset: prev.characterOffset)
            announceToVoiceOver("Bookmark \(prev.number)")
        }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        libraryViewModel.removeBookmark(bookID: book.id, bookmarkID: bookmark.id)
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
    }

    func navigateToBookmark(_ bookmark: Bookmark) {
        savePositionForReturn()
        navigateTo(chapterIndex: bookmark.chapterIndex, characterOffset: bookmark.characterOffset)
        autoPlayIfEnabled()
    }

    func navigateToSearchResult(chapterIndex: Int, characterOffset: Int) {
        savePositionForReturn()
        navigateTo(chapterIndex: chapterIndex, characterOffset: characterOffset)
        autoPlayIfEnabled()
    }

    /// If the auto-play-on-navigate setting is enabled and playback is not active, start playing.
    private func autoPlayIfEnabled() {
        guard settingsViewModel.autoPlayOnNavigate else { return }
        let isActive = isAudioBook
            ? (audioPlaybackService.isPlaying && !audioPlaybackService.isPaused)
            : (speechService.isSpeaking && !speechService.isPaused)
        if !isActive {
            togglePlayPause()
        }
    }

    /// Save current position so the user can return to it after browsing headings/bookmarks
    private func savePositionForReturn() {
        savedChapterIndex = currentChapterIndex
        savedCharacterOffset = currentCharacterOffset
        hasSavedPosition = true
    }

    /// Return to the position saved before the last heading/bookmark navigation
    func returnToSavedPosition() {
        guard hasSavedPosition else { return }
        hasSavedPosition = false
        navigateTo(chapterIndex: savedChapterIndex, characterOffset: savedCharacterOffset)
        announceToVoiceOver("Returned to previous position")
    }

    // MARK: - Metadata Editing

    func saveEPUBMetadata(_ metadata: EPUBMetadata, writeToFile: Bool) {
        epubMetadata = metadata

        book.title = metadata.title
        book.author = metadata.author

        if writeToFile && book.format == .epub {
            do {
                let url = URL(fileURLWithPath: book.filePath)
                let newHash = try EPUBParser.writeMetadata(metadata, to: url)
                book.md5Hash = newHash
                libraryViewModel.updateBookMetadata(book)
                announceToVoiceOver("Metadata saved to file")
            } catch {
                errorMessage = error.localizedDescription
                announceToVoiceOver("Failed to save metadata to file")
            }
        } else {
            libraryViewModel.updateBookMetadata(book)
            announceToVoiceOver("Metadata updated")
        }

        // Update NowPlaying with the new metadata
        nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: isCurrentlyPlaying && !isCurrentlyPaused
        )
    }

    /// Save edited audio metadata. Updates the book's title/author and persists
    /// the album, genre, and year fields to bookInfo.json inside the .tmb package.
    func saveAudioMetadata(_ metadata: AudioMetadata) {
        audioMetadata = metadata

        book.title = metadata.title
        book.author = metadata.artist
        book.audioAlbum = metadata.album
        book.audioGenre = metadata.genre
        book.audioYear = metadata.year

        libraryViewModel.updateBookMetadata(book)
        announceToVoiceOver("Metadata updated")

        // Update NowPlaying with the new metadata
        nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: isCurrentlyPlaying && !isCurrentlyPaused
        )
    }

    // MARK: - Audio Book Playback

    private func setupAudioCallbacks() {
        audioPlaybackService.onPositionUpdate = { [weak self] time in
            // AVPlayer time observer fires on main queue (setupTimeObserver uses queue: .main),
            // so this is already on the main thread
            guard let self = self, self.isAudioBook else { return }
            // Convert time position to character offset for position tracking
            let charOffset = Int(time * 10) // 10 chars per second in placeholder text
            self.currentCharacterOffset = charOffset
        }

        audioPlaybackService.onPlaybackFinished = { [weak self] in
            guard let self = self else { return }
            self.savePosition()
            self.sleepTimerService.notifyDocumentEnd()

            // Advance to next chapter (audio file)
            if let content = self.content {
                let nextIndex = self.currentChapterIndex + 1
                if nextIndex < content.chapters.count {
                    self.currentChapterIndex = nextIndex
                    self.currentCharacterOffset = 0
                    self.playAudioChapter()
                } else {
                    self.readingStatsService.endSession()
                    self.handleEndOfBook()
                }
            }
        }
    }

    private func playAudioChapter() {
        guard isAudioBook, let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let audioURL: URL
        if !audioChapterFiles.isEmpty && currentChapterIndex < audioChapterFiles.count {
            // Multi-file audio book
            audioURL = URL(fileURLWithPath: audioChapterFiles[currentChapterIndex])
        } else {
            // Single audio file — use book file path
            audioURL = URL(fileURLWithPath: book.filePath)
        }

        audioPlaybackService.load(url: audioURL)
        audioPlaybackService.setSpeed(audioSpeed)

        // If resuming mid-chapter, seek to the right position
        let timeOffset = Double(currentCharacterOffset) / 10.0
        audioPlaybackService.play(fromTime: timeOffset)

        isCurrentlyPlaying = true
        isCurrentlyPaused = false

        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    func adjustAudioSpeed(delta: Double) {
        let newSpeed = max(audioPlaybackService.minimumSpeed,
                          min(audioSpeed + delta, audioPlaybackService.maximumSpeed))
        audioSpeed = newSpeed
        audioPlaybackService.setSpeed(newSpeed)
        // Save as per-book setting
        book.localWPM = newSpeed
        libraryViewModel.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: book.localVoiceID, wpm: newSpeed)
        announceToVoiceOver(String(format: "%.2fx speed", newSpeed))
    }

    // MARK: - End of Book Behavior

    /// Called when the last chapter finishes playing.
    private func handleEndOfBook() {
        // Determine behavior: per-book override or global setting
        let behavior: EndOfBookBehavior
        if let localRaw = book.localEndOfBookBehavior,
           let local = EndOfBookBehavior(rawValue: localRaw) {
            behavior = local
        } else {
            behavior = settingsViewModel.endOfBookBehavior
        }

        switch behavior {
        case .stop:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: false
            )
            announceToVoiceOver("Finished: \(book.title)")

        case .loop:
            currentChapterIndex = 0
            currentCharacterOffset = 0
            chapterPlaybackGeneration += 1
            savePosition()
            announceToVoiceOver("Restarting: \(book.title)")
            speakCurrentChapter()
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )

        case .continueNext:
            readingStatsService.markBookFinished(bookID: book.id, title: book.title)
            savePosition()
            // Find the next book in the same folder by manual sort order
            if let nextBook = libraryViewModel.nextBookInFolder(after: book) {
                announceToVoiceOver("Starting: \(nextBook.title)")
                // Post notification to open next book (the app handles window management)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(
                        name: .continueToNextBook,
                        object: nil,
                        userInfo: ["bookID": nextBook.id, "previousBookID": self.book.id]
                    )
                }
            } else {
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: false
                )
                announceToVoiceOver("Finished: \(book.title). No more books in folder.")
            }
        }
    }

    /// The effective end-of-book behavior for this book
    var effectiveEndOfBookBehavior: EndOfBookBehavior {
        if let localRaw = book.localEndOfBookBehavior,
           let local = EndOfBookBehavior(rawValue: localRaw) {
            return local
        }
        return settingsViewModel.endOfBookBehavior
    }

    func setLocalEndOfBookBehavior(_ behavior: EndOfBookBehavior?) {
        book.localEndOfBookBehavior = behavior?.rawValue
        libraryViewModel.updateEndOfBookBehavior(bookID: book.id, behavior: behavior?.rawValue)
    }

    // MARK: - Rewind on Resume

    private func recordPlaybackStarted() {
        book.lastPlaybackStarted = Date()
        libraryViewModel.updatePlaybackTimestamps(
            bookID: book.id,
            started: book.lastPlaybackStarted,
            stopped: book.lastPlaybackStopped
        )
    }

    private func recordPlaybackStopped() {
        book.lastPlaybackStopped = Date()
        libraryViewModel.updatePlaybackTimestamps(
            bookID: book.id,
            started: book.lastPlaybackStarted,
            stopped: book.lastPlaybackStopped
        )
    }

    /// Check settings and apply rewind-on-resume if appropriate.
    /// Called before speechService.resume() so the seek takes effect on the paused state.
    private func applyRewindOnResume() {
        let unit = settingsViewModel.rewindOnResumeUnit
        guard unit != .none else { return }

        // Smart mode: only rewind if pause was long enough
        if settingsViewModel.rewindSmartMode {
            guard let stoppedAt = book.lastPlaybackStopped else { return }
            let elapsed = Date().timeIntervalSince(stoppedAt)
            if elapsed < settingsViewModel.rewindSmartThreshold {
                debugLog("rewindOnResume: smart mode skip, elapsed=\(Int(elapsed))s < threshold=\(Int(settingsViewModel.rewindSmartThreshold))s")
                return
            }
        }

        guard let content = content,
              currentChapterIndex < content.chapters.count else { return }

        let text = content.chapters[currentChapterIndex].text
        let offset = currentCharacterOffset

        switch unit {
        case .none:
            break
        case .sentence:
            let newOffset = findSentenceStart(in: text, before: offset)
            if newOffset < offset {
                debugLog("rewindOnResume: sentence rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                speechService.seek(toCharOffset: newOffset)
            }
        case .paragraph:
            let newOffset = findParagraphStart(in: text, before: offset)
            if newOffset < offset {
                debugLog("rewindOnResume: paragraph rewind \(offset) -> \(newOffset)")
                currentCharacterOffset = newOffset
                speechService.seek(toCharOffset: newOffset)
            }
        case .heading:
            if let heading = currentHeadingAtPosition() {
                let headingOffset = heading.chapterIndex == currentChapterIndex ? heading.characterOffset : 0
                if headingOffset < offset {
                    debugLog("rewindOnResume: heading rewind \(offset) -> \(headingOffset)")
                    currentCharacterOffset = headingOffset
                    speechService.seek(toCharOffset: headingOffset)
                }
            }
        }
    }

    /// Find the start of the current sentence by scanning backward for sentence-ending punctuation.
    private func findSentenceStart(in text: String, before offset: Int) -> Int {
        guard offset > 0, offset <= text.count else { return 0 }
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        let idx = text.index(text.startIndex, offsetBy: min(offset - 1, text.count - 1))

        // Walk backward to find the end of the previous sentence
        var pos = idx
        while pos > text.startIndex {
            pos = text.index(before: pos)
            if sentenceEnders.contains(text[pos]) {
                // Move past the punctuation and any whitespace
                var start = text.index(after: pos)
                while start < text.endIndex && text[start].isWhitespace {
                    start = text.index(after: start)
                }
                return text.distance(from: text.startIndex, to: start)
            }
        }
        return 0 // No sentence boundary found — rewind to start of chapter
    }

    /// Find the start of the current paragraph by scanning backward for double newlines.
    private func findParagraphStart(in text: String, before offset: Int) -> Int {
        guard offset > 1, offset <= text.count else { return 0 }
        let searchEnd = min(offset - 1, text.count - 1)
        let idx = text.index(text.startIndex, offsetBy: searchEnd)

        var pos = idx
        while pos > text.startIndex {
            let prev = text.index(before: pos)
            if text[pos] == "\n" && text[prev] == "\n" {
                // Move past the newlines
                var start = text.index(after: pos)
                while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                    start = text.index(after: start)
                }
                return text.distance(from: text.startIndex, to: start)
            }
            pos = prev
        }
        return 0 // No paragraph boundary found — rewind to start of chapter
    }

    // MARK: - Punctuation Pauses

    /// Insert extra pause characters at punctuation to slow down dense text.
    /// Level 0 = off, 1 = subtle (periods), 2 = moderate (periods + commas), 3 = heavy (+ paragraph breaks)
    private func applyPunctuationPauses(_ text: String) -> String {
        let level = settingsViewModel.punctuationPauseLevel
        guard level > 0 else { return text }

        // Use a period followed by space as a natural TTS pause cue
        let periodPause = ". "     // Extra pause after sentences
        let commaPause = ", "      // Extra pause after commas
        let paragraphPause = ".\n\n" // Extra pause at paragraph breaks

        var result = text

        // Level 1+: Extra pause after sentence-ending punctuation
        if level >= 1 {
            result = result.replacingOccurrences(of: ". ", with: ".\(periodPause)")
            result = result.replacingOccurrences(of: "! ", with: "!\(periodPause)")
            result = result.replacingOccurrences(of: "? ", with: "?\(periodPause)")
        }

        // Level 2+: Extra pause after commas
        if level >= 2 {
            result = result.replacingOccurrences(of: ", ", with: ",\(commaPause)")
        }

        // Level 3: Extra pause at paragraph breaks
        if level >= 3 {
            result = result.replacingOccurrences(of: "\n\n", with: "\n\n\(paragraphPause)")
        }

        return result
    }

    // MARK: - Position Saving

    private func savePosition() {
        let position = ReadingPosition(
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            globalCharacterOffset: currentGlobalOffset
        )
        libraryViewModel.updateReadingPosition(bookID: book.id, position: position)
    }

    // MARK: - Where Am I?

    /// Pauses the book (if playing), then speaks a summary of current position
    /// using a separate synthesizer so the book engine state is preserved.
    /// First press: brief summary (chapter, percentage).
    /// Quick second press (within 3 seconds): full details including heading, time estimates.
    /// If already speaking: stops the announcement.
    func whereAmI() {
        // If already speaking a Where Am I announcement, stop it
        if isWhereAmISpeaking {
            whereAmISynth.stopSpeaking(at: .immediate)
            isWhereAmISpeaking = false
            if wasPlayingBeforeWhereAmI {
                wasPlayingBeforeWhereAmI = false
                if isAudioBook {
                    audioPlaybackService.resume()
                } else {
                    speechService.resume()
                }
                nowPlayingService.updateNowPlayingInfo(
                    title: book.title, author: book.author, isPlaying: true
                )
            }
            return
        }

        // Determine detail level: brief on first press, full on quick second press
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastWhereAmITime)
        let useFull = timeSinceLast < 3.0
        lastWhereAmITime = now

        if isAudioBook {
            wasPlayingBeforeWhereAmI = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
        } else {
            wasPlayingBeforeWhereAmI = speechService.isSpeaking && !speechService.isPaused
        }

        soundEffectService?.play(for: .whereAmIStart)

        // Pause the book if it's currently playing (without the normal pause sound)
        if wasPlayingBeforeWhereAmI {
            if isAudioBook {
                audioPlaybackService.pause()
            } else {
                speechService.pause()
            }
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: false
            )
            savePosition()
        }

        guard let content = content else {
            speakWhereAmI("No book is loaded.")
            return
        }

        let summary = useFull ? buildFullWhereAmI(content: content) : buildBriefWhereAmI(content: content)
        speakWhereAmI(summary)
    }

    /// Brief summary: title, chapter name, position, percentage
    private func buildBriefWhereAmI(content: DocumentContent) -> String {
        var parts: [String] = []
        parts.append(book.title)
        // Include the current heading name so the user knows where they are semantically
        if let currentHeading = currentHeadingAtPosition() {
            parts.append(currentHeading.text)
        } else if currentChapterIndex < content.chapters.count {
            // Fall back to chapter title if no heading found
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append(chapter.title)
            }
        }
        if currentChapterIndex < content.chapters.count {
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }
        parts.append(String(format: "%.0f percent", percentComplete))
        parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining")
        return parts.joined(separator: ". ") + "."
    }

    /// Full summary: title, chapter, heading, time remaining in heading, total book time
    private func buildFullWhereAmI(content: DocumentContent) -> String {
        var parts: [String] = []
        parts.append(book.title)
        if currentChapterIndex < content.chapters.count {
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append("Chapter: \(chapter.title)")
            }
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }
        parts.append(String(format: "%.0f percent through the book", percentComplete))
        parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining")
        if let currentHeading = currentHeadingAtPosition() {
            parts.append("Current heading: \(currentHeading.text)")
            let headingTime = timeEstimateForHeading(currentHeading)
            let headingGlobalStart = content.globalOffset(chapterIndex: currentHeading.chapterIndex, localOffset: currentHeading.characterOffset)
            let headingElapsed = currentGlobalOffset - headingGlobalStart
            let totalHeadingChars = estimatedCharsInHeading(currentHeading)
            if totalHeadingChars > 0 {
                let fractionRemaining = max(0, 1.0 - Double(headingElapsed) / Double(totalHeadingChars))
                let headingRemaining = headingTime * fractionRemaining
                parts.append("\(TimeFormatting.spoken(headingRemaining)) remaining in this heading")
            }
        }
        parts.append("Total book time: \(TimeFormatting.spoken(totalEstimatedTime))")
        return parts.joined(separator: ". ") + "."
    }

    /// Cancel a Where Am I announcement if one is active, resuming book playback if it was playing before.
    /// Used by skip/play/pause to cleanly interrupt an announcement.
    private func cancelWhereAmIIfActive() {
        guard isWhereAmISpeaking else { return }
        whereAmISynth.stopSpeaking(at: .immediate)
        isWhereAmISpeaking = false
        // Resume book if it was playing before Where Am I interrupted it
        if wasPlayingBeforeWhereAmI {
            wasPlayingBeforeWhereAmI = false
            if isAudioBook {
                audioPlaybackService.resume()
            } else {
                speechService.resume()
            }
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: true
            )
        }
    }

    private func speakWhereAmI(_ text: String) {
        whereAmISynth.stopSpeaking(at: .immediate)

        // Set self as delegate via the WhereAmIDelegateHelper
        let delegate = WhereAmIDelegateHelper { [weak self] in
            guard let self = self else { return }
            self.isWhereAmISpeaking = false
            self.soundEffectService?.play(for: .whereAmIEnd)
            if self.wasPlayingBeforeWhereAmI {
                self.wasPlayingBeforeWhereAmI = false
                // Small delay to let sound effect play
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    if self.isAudioBook {
                        self.audioPlaybackService.resume()
                    } else {
                        self.speechService.resume()
                    }
                    self.nowPlayingService.updateNowPlayingInfo(
                        title: self.book.title, author: self.book.author, isPlaying: true
                    )
                }
            }
        }
        self.whereAmIDelegate = delegate
        whereAmISynth.delegate = delegate

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(speechService.wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false

        isWhereAmISpeaking = true
        whereAmISynth.speak(utterance)
    }

    /// Prevent delegate from being deallocated
    private var whereAmIDelegate: WhereAmIDelegateHelper?

    /// Find the heading at or before the current reading position
    private func currentHeadingAtPosition() -> Heading? {
        guard let content = content else { return nil }
        let allHeadings = content.allHeadings
        return allHeadings.last(where: {
            $0.chapterIndex < currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset <= currentCharacterOffset)
        })
    }

    /// Estimated character count for a heading section (from heading start to next heading or end of book)
    private func estimatedCharsInHeading(_ heading: Heading) -> Int {
        guard let content = content else { return 0 }
        let allHeadings = content.allHeadings
        let headingGlobalStart = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        var nextOffset = content.totalCharacterCount
        if let idx = allHeadings.firstIndex(where: { $0.id == heading.id }),
           idx + 1 < allHeadings.count {
            let next = allHeadings[idx + 1]
            nextOffset = content.globalOffset(chapterIndex: next.chapterIndex, localOffset: next.characterOffset)
        }
        return nextOffset - headingGlobalStart
    }

    // MARK: - Copy Reading Position

    func copyReadingPosition() {
        guard let content = content else { return }

        var parts: [String] = []
        parts.append(book.title)
        if !book.author.isEmpty && book.author != "Unknown" {
            parts.append("by \(book.author)")
        }

        if currentChapterIndex < content.chapters.count {
            let chapter = content.chapters[currentChapterIndex]
            if !chapter.title.isEmpty {
                parts.append("Chapter: \(chapter.title)")
            }
            parts.append("Chapter \(currentChapterIndex + 1) of \(content.chapters.count)")
        }

        if let heading = currentHeadingAtPosition() {
            parts.append("Heading: \(heading.text)")
        }

        parts.append(String(format: "%.1f%% through", percentComplete))
        parts.append("\(formattedTimeRemaining) remaining")

        let positionText = parts.joined(separator: " | ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(positionText, forType: .string)
        announceToVoiceOver("Reading position copied to clipboard")
    }

    // MARK: - VoiceOver Announcement

    private func announceToVoiceOver(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    deinit {
        speechService.stop()
        audioPlaybackService.stop()
        whereAmISynth.stopSpeaking(at: .immediate)
        nowPlayingService.clearNowPlaying()
        libraryViewModel.unregisterOpenBook(book.id)
    }
}

// MARK: - Where Am I Delegate

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
