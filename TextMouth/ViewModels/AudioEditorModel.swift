import AppKit
import Combine

/// What the audio editor window shows and does (FR04): one audio file of a
/// book, open for editing through its edit session (`AudioEditSession`),
/// played through a preview of the edited audio, with the book's chapter
/// markers and the pauses found in it.
///
/// Everything is reachable by the keyboard and VoiceOver; nothing depends
/// on a waveform. The time display says where the cursor is, the status
/// line says the rest, and every command says what it did once, through
/// the app's announcer, and shows it again on the message line so a
/// braille display can read it. Nothing is announced while the audio plays
/// unless asked for. Every edit goes through the session and hands the
/// player the new preview at the same place.
///
/// The commands live in extensions by what they do: listening and moving
/// (`AudioEditorModel+Listening`), selecting and markers
/// (`AudioEditorModel+Selecting`), and the dispatch of commands from
/// buttons and shortcuts (`AudioEditorModel+Commands`). The state they
/// change is declared here, and only the model's own commands change it.
@MainActor
final class AudioEditorModel: ObservableObject {
    // MARK: The Book

    /// The book whose audio is edited.
    let bookID: UUID
    /// The book's title, as the window names it.
    let bookTitle: String
    /// The track's chapter name in a book of several tracks; nil for a book
    /// of one file.
    let trackTitle: String?
    /// The edit session: the edit list, the edited audio's timeline, undo
    /// and redo, saving, and export.
    let session: AudioEditSession
    /// What the preview plays through.
    let player: AudioEditorPlayback
    /// The preferences store the editor's settings and the shortcuts are
    /// read from.
    let store: UserDefaults
    /// The editor's window, once it is open: the window its shortcuts are
    /// pressed in, and its announcements are posted from.
    weak var hostWindow: NSWindow?

    // MARK: Published State

    /// Where the cursor is, in seconds on the edited audio: where playing
    /// starts, and where the commands act. It follows the audio while it
    /// plays.
    @Published var cursor: TimeInterval = 0
    /// Whether the audio is playing for listening; a half-second scrub
    /// after a move is not counted.
    @Published var isPlaying = false
    /// Whether the player holds the edited audio, so it can play.
    @Published var hasPreview = false
    /// The last sentence announced, shown on the message line.
    @Published var lastMessage = ""
    /// The levels of the edited audio, once measured: what the pauses are
    /// found in and the waveform draws.
    @Published var levels: AudioEditorLevels?
    /// The pauses found in the edited audio, in order.
    @Published var pauses: [AudioEditorPause] = []
    /// Where the search for pauses is.
    @Published var pauseSearch: PauseSearch = .finding
    /// The sheet over the window now, if any: a question with one field,
    /// or a list. One at a time, so a sheet never opens over another.
    @Published var sheet: AudioEditorSheet?
    /// The selection's start, marked with In; nil while unmarked, when a
    /// marked Out selects from the start of the audio.
    @Published var selectionStart: TimeInterval?
    /// The selection's end, marked with Out; nil while unmarked, when a
    /// marked In selects to the end of the audio.
    @Published var selectionEnd: TimeInterval?
    /// The markers dropped, in the order they were dropped; listed in time
    /// order (`orderedMarkers`).
    @Published var markers: [AudioEditorMarker] = []
    /// Whether an edit, a save, or an export is under way: every other
    /// command that would change the audio waits for it, saying so.
    @Published var isWorking = false
    /// The punch-in under way, from its count-in to its take, if any.
    @Published var punchIn: AudioEditorPunchIn?
    /// The microphones a punch-in can record from, distinctly named.
    @Published var microphones: [AudioInputDevice] = []
    /// The microphone a punch-in records from: the one TextMouth remembers,
    /// or macOS's default input; empty with none connected.
    @Published var microphoneID = ""
    /// What Apply Filter's Preview is playing, if anything.
    @Published var filterPreview: AudioEditorFilterPreview?
    /// What was last previewed since Apply Filter opened, whether or not it
    /// still plays: with "Preview filters before applying" on, Apply of
    /// anything else previews first.
    var previewedFilter: AudioEditorFilterPreview?
    /// A save or an export under way, as its sheet shows it.
    @Published var progress: AudioEditorProgress?
    /// Whether Revert to Original is asking to be confirmed.
    @Published var confirmingRevert = false
    /// The format a save writes the book's file in, by name, once read.
    @Published var saveFormatName: String?
    /// Whether the window reopens the book's reader as it closes: the
    /// launcher closed that reader to open the editor.
    var reopensReaderOnClose = false

    /// What Copy or Cut kept for Paste.
    var clip: AudioEditorClip?
    /// The second edit of each Trim to Selection made of two, by its
    /// identity, with the first's: undone and redone as one.
    var pairedEdits: [UUID: UUID] = [:]
    /// What punch-ins record with.
    let recorder: AudioEditorRecorder
    /// Follow the recorder: a take that ends on its own, and the time and
    /// level the status line shows while recording.
    var recorderSubscriptions: Set<AnyCancellable> = []
    /// This window's folder for audio copied or cut, made when first used
    /// and removed as the window closes.
    let clipFolder: URL

    /// Where the search for pauses is.
    enum PauseSearch: Equatable {
        /// The edited audio's levels are being measured.
        case finding
        /// The pauses are found, as the audio is now.
        case found
        /// They couldn't be found, for the reason given.
        case failed(String)
    }

    /// What the player is doing for the editor.
    enum Playing: Equatable {
        /// Nothing.
        case idle
        /// Playing for listening, since `from`, where Stop goes back to.
        case listening(from: TimeInterval)
        /// Playing half a second after a move, the cursor staying put.
        case scrubbing
        /// Playing Apply Filter's preview of processed sound, in place of
        /// the edited audio, until it stops.
        case previewing
    }

    /// What the player is doing for the editor.
    var playing: Playing = .idle

    // MARK: Collaborators

    /// Makes VoiceOver speak a sentence.
    private let announcer: @MainActor (String) -> Void
    /// Forwards the session's changes, so the window follows its undo
    /// names, its length, and its chapter markers.
    private var sessionChanges: AnyCancellable?
    /// Takes the editor's shortcuts as the shortcut manager posts them.
    private var shortcutObserver: NSObjectProtocol?
    /// Follows the shortcuts in the preferences store, so the buttons' hints
    /// name the keys in force.
    private var bindingsObserver: PreferenceObserver?
    /// The measurement of the edited audio's levels under way.
    var measuring: Task<Void, Never>?
    /// Counts what the player is handed, so only the newest load of the
    /// preview reaches it, and a filter's preview stops any older load.
    var previewLoads = 0

    /// A model for the editor window of the book `bookID`, titled
    /// `bookTitle`, editing through `session` and playing through `player`.
    /// - Parameters:
    ///   - trackTitle: The track's chapter name in a book of several tracks.
    ///   - store: The preferences store the editor's settings, the
    ///     shortcuts, and the microphone chosen are read from.
    ///   - recorder: What punch-ins record with.
    ///   - clipFolder: Where the window keeps audio copied or cut; a folder
    ///     of its own in this Mac's caches unless a test gives one.
    ///   - announce: Makes VoiceOver speak.
    init(
        bookID: UUID,
        bookTitle: String,
        trackTitle: String?,
        session: AudioEditSession,
        player: AudioEditorPlayback,
        store: UserDefaults,
        recorder: AudioEditorRecorder,
        clipFolder: URL = AudioEditorClip.newFolder(),
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.trackTitle = trackTitle
        self.session = session
        self.player = player
        self.store = store
        self.recorder = recorder
        self.clipFolder = clipFolder
        announcer = announce
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        player.onTime = { [weak self] time in self?.playerMoved(to: time) }
        player.onStop = { [weak self] in self?.playerStopped() }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .audioEditorShortcut,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Read on the main queue it is delivered on, then handed on.
            let action = (notification.userInfo?["action"] as? String).flatMap(ShortcutAction.init(rawValue:))
            let source = notification.userInfo?["sourceWindow"] as? NSWindow
            MainActor.assumeIsolated { self?.shortcutPressed(action, in: source) }
        }
        bindingsObserver = PreferenceObserver(keys: [KeyboardShortcutManager.bindingsPreference.key], in: store) { [weak self] _ in
            self?.objectWillChange.send()
        }
        followRecorder()
    }

    // MARK: State

    /// The window's title.
    var windowTitle: String {
        AudioEditorWording.windowTitle(book: bookTitle, track: trackTitle)
    }

    /// How long the edited audio lasts, in seconds.
    var duration: TimeInterval {
        session.duration
    }

    /// The time display, as it shows.
    var positionText: String {
        AudioEditorWording.positionText(cursor, of: duration)
    }

    /// The time display, as VoiceOver speaks it.
    var positionValue: String {
        AudioEditorWording.positionValue(cursor, of: duration)
    }

    /// The chapter markers, as times in seconds with their titles, in order.
    var chapters: [(start: TimeInterval, title: String)] {
        session.chapters
    }

    /// The index in `chapters` of the chapter `time` is in: the last marker
    /// at or before it, a marker exactly at the time counting; nil before
    /// the first marker, or without any.
    func chapterIndex(at time: TimeInterval) -> Int? {
        chapters.lastIndex { $0.start <= time + Self.timeTolerance }
    }

    /// The status line: whether the audio is playing, where the cursor is,
    /// of how long the audio lasts, in which chapter, and what is selected.
    var statusSentence: String {
        var parts = isPlaying ? [AudioEditorWording.playing] : []
        if let punchInStatus {
            parts.append(punchInStatus)
        }
        parts.append(positionValue)
        if let index = chapterIndex(at: cursor), chapters.indices.contains(index) {
            parts.append(AudioEditorWording.inChapter(number: index + 1, title: chapters[index].title))
        }
        if let selection {
            parts.append(AudioEditorWording.selectionPart(selection))
        }
        return AudioEditorWording.status(parts)
    }

    /// The question asked in a sheet now, if the sheet asks one.
    var prompt: AudioEditorPrompt? {
        get {
            if case .prompt(let prompt) = sheet { return prompt }
            return nil
        }
        set { sheet = newValue.map(AudioEditorSheet.prompt) }
    }

    /// What is selected: from In, or the start, to Out, or the end, once
    /// either is marked and they make a stretch of some length; nil
    /// otherwise.
    var selection: AudioTimeRange? {
        guard selectionStart != nil || selectionEnd != nil else { return nil }
        let start = clamped(selectionStart ?? 0)
        let end = clamped(selectionEnd ?? duration)
        guard end - start > Self.timeTolerance else { return nil }
        return AudioTimeRange(start: start, end: end)
    }

    /// How close two times must be to count as the same place: half a
    /// millisecond, less than any edit can tell apart and more than a
    /// time's rounding to a sample.
    static let timeTolerance: TimeInterval = 0.000_5

    /// `time` kept inside the audio, from its start to its end.
    func clamped(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(0, time), duration)
    }

    // MARK: Shortcuts

    /// The keys bound to `action` now, as the preferences store holds them.
    func bindings(for action: ShortcutAction) -> [KeyBinding] {
        KeyboardShortcutManager.bindingsPreference.read(from: store)[action] ?? []
    }

    /// Performs `action`, an editor shortcut pressed in `source`, when that
    /// is this editor's window.
    private func shortcutPressed(_ action: ShortcutAction?, in source: NSWindow?) {
        guard let action,
              WindowCommandRouting.shouldAccept(sourceWindow: source, hostWindow: hostWindow, keyWindow: NSApp.keyWindow) else { return }
        perform(action)
    }

    // MARK: The Preview

    /// Hands the player the edited audio as it now is, at the cursor, kept
    /// inside the audio, then, when `measuring`, measures its levels again
    /// for the pauses: after an edit, not after a filter's preview, which
    /// changed nothing. A preview that can't be made is announced: the
    /// window stays open, and the next edit or undo tries again.
    func loadPreview(measuring: Bool = true) async {
        // Only the newest load hands the player its audio: an older one
        // still making its composition was of audio since changed.
        previewLoads += 1
        let load = previewLoads
        do {
            let preview = try await session.makePreview()
            guard load == previewLoads else { return }
            cursor = clamped(cursor)
            playing = .idle
            isPlaying = false
            player.load(preview, at: cursor)
            hasPreview = true
        } catch {
            hasPreview = false
            announce(error.localizedDescription)
        }
        if measuring {
            measureLevels()
        }
    }

    // MARK: Announcing

    /// Says `sentence` through VoiceOver and shows it on the message line.
    func announce(_ sentence: String) {
        lastMessage = sentence
        announcer(sentence)
    }

    // MARK: Closing

    /// Lets go of everything the window holds as it closes: a punch-in
    /// under way, discarded; the player; the measurement under way; the
    /// observers; the audio kept for Paste; and the edit session, whose use
    /// of the book ends.
    func windowClosed() {
        measuring?.cancel()
        measuring = nil
        abandonPunchIn()
        player.close()
        session.close()
        sessionChanges = nil
        recorderSubscriptions = []
        recorder.catalog.onChange = nil
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
            self.shortcutObserver = nil
        }
        bindingsObserver = nil
        clip = nil
        try? FileManager.default.removeItem(at: clipFolder)
    }
}
