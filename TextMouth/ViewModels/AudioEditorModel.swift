import AppKit
import Combine

/// What the audio editor window shows and does (FR04): one audio file of a
/// book, open for editing through its edit session (`AudioEditSession`),
/// played through a preview of the edited audio, with the book's chapter
/// markers.
///
/// Everything is reachable by the keyboard and VoiceOver; nothing depends
/// on a waveform. The time display says where the cursor is, the status
/// line says the rest, and every command says what it did once, through
/// the app's announcer, and shows it again on the message line so a
/// braille display can read it. Every edit goes through the session and
/// hands the player the new preview at the same place.
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
    /// The preferences store the editor's settings are read from.
    let store: UserDefaults

    // MARK: Published State

    /// Where the cursor is, in seconds on the edited audio: where playing
    /// starts, and where the commands act.
    @Published private(set) var cursor: TimeInterval = 0
    /// The last sentence announced, shown on the message line.
    @Published private(set) var lastMessage = ""

    // MARK: Collaborators

    /// Makes VoiceOver speak a sentence.
    private let announcer: @MainActor (String) -> Void
    /// Forwards the session's changes, so the window follows its undo
    /// names, its length, and its chapter markers.
    private var sessionChanges: AnyCancellable?

    /// A model for the editor window of the book `bookID`, titled
    /// `bookTitle`, editing through `session` and playing through `player`.
    /// - Parameters:
    ///   - trackTitle: The track's chapter name in a book of several tracks.
    ///   - store: The preferences store the editor's settings are read from.
    ///   - announce: Makes VoiceOver speak.
    init(
        bookID: UUID,
        bookTitle: String,
        trackTitle: String?,
        session: AudioEditSession,
        player: AudioEditorPlayback,
        store: UserDefaults,
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.trackTitle = trackTitle
        self.session = session
        self.player = player
        self.store = store
        announcer = announce
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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

    /// The status line: where the cursor is, of how long the audio lasts,
    /// and in which chapter.
    var statusSentence: String {
        var parts = [positionValue]
        if let index = chapterIndex(at: cursor), chapters.indices.contains(index) {
            parts.append(AudioEditorWording.inChapter(number: index + 1, title: chapters[index].title))
        }
        return AudioEditorWording.status(parts)
    }

    /// How close two times must be to count as the same place: half a
    /// millisecond, less than any edit can tell apart and more than a
    /// time's rounding to a sample.
    static let timeTolerance: TimeInterval = 0.000_5

    // MARK: The Preview

    /// Hands the player the edited audio as it now is, at the cursor, kept
    /// inside the audio. A preview that can't be made is announced: the
    /// window stays open, and the next edit or undo tries again.
    func loadPreview() async {
        do {
            let preview = try await session.makePreview()
            cursor = min(max(0, cursor), duration)
            player.load(preview, at: cursor)
        } catch {
            announce(error.localizedDescription)
        }
    }

    // MARK: Announcing

    /// Says `sentence` through VoiceOver and shows it on the message line.
    func announce(_ sentence: String) {
        lastMessage = sentence
        announcer(sentence)
    }

    // MARK: Closing

    /// Lets go of everything the window holds as it closes: the player and
    /// the edit session, whose use of the book ends.
    func windowClosed() {
        player.close()
        session.close()
        sessionChanges = nil
    }
}
