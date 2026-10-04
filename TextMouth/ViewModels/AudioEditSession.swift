import AVFoundation

/// One audio file of a book open for editing (FR04): the model the editor
/// window works through, and everything here works without it.
///
/// A session holds the file's edit list as edits.json keeps it and the
/// edited audio as the applied edits leave it (`timeline`: its length and
/// chapter markers), and changes both only through the history store, off
/// the main thread, so what it shows is always what the package records.
/// Every change is validated against the audio first: an edit that doesn't
/// fit throws a sentence saying why (`AudioEditError.invalidEdit`) and
/// changes nothing. A preview is a composition of the timeline for an
/// `AVPlayer`, sample-exact; saving renders the edits into the book's file
/// through the library (`LibraryViewModel.saveAudioEdits`).
///
/// While a session is open it holds a use of the book, so the original
/// policy never deletes the original it previews from; the use ends with
/// `close()`, or when the session is released.
@MainActor
final class AudioEditSession: ObservableObject {
    /// The book.
    let bookID: UUID
    /// The file edited, by its path inside the package: another name once a
    /// save writes it in a format of another extension.
    @Published private(set) var audioFile: String
    /// The file's edit list, as edits.json holds it.
    @Published private(set) var list: AudioEditList
    /// The edited audio as the applied edits leave it.
    @Published private(set) var timeline: AudioEditTimeline
    /// The book's own original policy; nil follows the global setting.
    @Published private(set) var policyOverride: AudioOriginalPolicy?

    /// The library the book is in.
    private weak var library: LibraryViewModel?
    /// Where the book's package is.
    private let place: AudioBookPlace
    /// The audio the edits start from.
    private var base: AudioEditBase
    /// This Mac's scratch folder for the book.
    private let scratch: URL
    /// Makes what renders filters and gain changes.
    private let makeProcessor: AudioEditProcessorFactory
    /// What renders filters and gain changes for edits over `base`; nil
    /// refuses them.
    private var processor: (any AudioEditProcessing)?
    /// The session's use of the book.
    private let lease: AudioEditActivity.Lease
    /// The timelines made so far, by the newest applied edit over the base
    /// ("" for none), so undo and redo need not apply the list again.
    private var timelines: [String: AudioEditTimeline] = [:]

    private init(
        bookID: UUID,
        audioFile: String,
        list: AudioEditList,
        timeline: AudioEditTimeline,
        policyOverride: AudioOriginalPolicy?,
        library: LibraryViewModel,
        place: AudioBookPlace,
        base: AudioEditBase,
        scratch: URL,
        makeProcessor: @escaping AudioEditProcessorFactory,
        lease: AudioEditActivity.Lease
    ) {
        self.bookID = bookID
        self.audioFile = audioFile
        self.list = list
        self.timeline = timeline
        self.policyOverride = policyOverride
        self.library = library
        self.place = place
        self.base = base
        self.scratch = scratch
        self.makeProcessor = makeProcessor
        processor = makeProcessor(AudioEditComposition.Sources(base: base, package: place.package, scratch: scratch))
        self.lease = lease
        timelines[Self.key(of: list)] = timeline
    }

    // MARK: Opening

    /// Opens `audioFile` (by its path inside the package; the book's own
    /// file when nil) of the book `bookID` in `library` for editing.
    /// With `startingOver`, a history that cannot be read, already preserved
    /// beside itself, is replaced by an empty one.
    /// - Throws: `AudioEditError.bookNotInLibrary`, the history store's
    ///   errors (`.historyUnusable` without `startingOver`), or the base
    ///   audio's (`.missingAudio`, `.audioInCloud`, `.unreadableAudio`).
    static func open(
        bookID: UUID,
        audioFile: String? = nil,
        in library: LibraryViewModel,
        startingOver: Bool = false
    ) async throws -> AudioEditSession {
        guard let book = library.bookByID(bookID), book.format.isAudio, !book.tmbDirectoryName.isEmpty else {
            throw AudioEditError.bookNotInLibrary
        }
        let place = AudioBookPlace(book: book)
        let file = audioFile ?? place.bookFile
        // The use begins before the history is read, so the original policy
        // never deletes the original this session starts from.
        let lease = library.audioEditActivity.lease(bookID)
        do {
            let (list, policy) = try await Self.changeHistory(place: place, startingOver: startingOver) { history in
                (history.listOrNew(for: file), history.policyOverride)
            }
            let base = try await Self.loadBase(of: list, place: place)
            let scratch = try AudioEditScratch.folder(for: bookID)
            let makeProcessor = library.audioEditProcessorFactory()
            let processor = makeProcessor(AudioEditComposition.Sources(base: base, package: place.package, scratch: scratch))
            let timeline = try await Self.timeline(of: list, over: base, processor: processor)
            return AudioEditSession(
                bookID: bookID,
                audioFile: file,
                list: list,
                timeline: timeline,
                policyOverride: policy,
                library: library,
                place: place,
                base: base,
                scratch: scratch,
                makeProcessor: makeProcessor,
                lease: lease
            )
        } catch {
            lease.end()
            throw error
        }
    }

    // MARK: State

    /// How long the edited audio lasts, in seconds.
    var duration: TimeInterval {
        timeline.duration
    }

    /// The chapter markers, as times in seconds with their titles.
    var chapters: [(start: TimeInterval, title: String)] {
        timeline.chapterTimes
    }

    /// Whether an edit can be undone (`AudioEditList.canUndo`).
    var canUndo: Bool {
        list.canUndo
    }

    /// Whether an undone edit can be redone.
    var canRedo: Bool {
        list.canRedo
    }

    /// The Edit menu's name for what Undo would undo: "Cut 2.5 Seconds".
    var undoActionName: String? {
        list.nextUndo.map { AudioEditWording.actionName($0.edit) }
    }

    /// The Edit menu's name for what Redo would redo.
    var redoActionName: String? {
        list.nextRedo.map { AudioEditWording.actionName($0.edit) }
    }

    /// Why undo can go no further, as a sentence, or nil when it can.
    var undoLimitExplanation: String? {
        AudioEditWording.undoLimit(list.undoLimit)
    }

    /// Whether edits wait to be saved into the book's file.
    var hasUnsavedEdits: Bool {
        !list.isRendered
    }

    // MARK: Editing

    /// Makes `edit` and returns its entry, once it is in the history.
    /// - Throws: `AudioEditError.invalidEdit` with a sentence saying why it
    ///   doesn't fit, a filter's errors, or the history store's.
    @discardableResult
    func perform(_ edit: AudioEdit) async throws -> AudioEditEntry {
        var next = timeline
        try await next.apply(edit, processor: processor)
        let file = audioFile
        let before = list
        let (list, entry) = try await Self.changeHistory(place: place) { history in
            var list = history.listOrNew(for: file)
            let entry = list.record(edit, at: Date())
            history.setList(list)
            return (list, entry)
        }
        try await adopt(list, expecting: next, after: before)
        return entry
    }

    /// Replaces `range` of the audio with a take recorded for it, the audio
    /// file at `url` (a punch-in), of which `takeRange` is used, all of it
    /// when nil. The take is kept in the book's package (compressed where
    /// that loses nothing) under the same lock that records the edit.
    /// - Throws: as `perform(_:)` does, or the take's own read error.
    @discardableResult
    func punchIn(replacing range: AudioTimeRange, withTakeAt url: URL, using takeRange: AudioTimeRange? = nil) async throws -> AudioEditEntry {
        let takeLength = try await Self.length(of: url)
        let used = takeRange ?? AudioTimeRange(start: 0, end: takeLength)
        guard used.isWellFormed, used.end <= takeLength + 0.001 else {
            throw AudioEditError.invalidEdit("The stretch of the take to use isn't inside the take.")
        }
        // Checked with a stand-in for the take's place, which the history
        // gives it only as the edit is recorded.
        var check = timeline
        try check.applyRearranging(.replace(range, with: AudioEditTake(file: "take", range: used)))
        let file = audioFile
        let package = place.package
        let before = list
        let (list, entry) = try await Self.changeHistory(place: place) { history in
            let take = AudioEditTake(file: try AudioEditPackage.keepTake(from: url, inPackage: package), range: used)
            var list = history.listOrNew(for: file)
            let entry = list.record(.replace(range, with: take), at: Date())
            history.setList(list)
            return (list, entry)
        }
        var next = timeline
        try await next.apply(entry.edit, processor: processor)
        try await adopt(list, expecting: next, after: before)
        return entry
    }

    /// Undoes the newest applied edit and returns it; nil, with nothing
    /// changed, when none can be undone (`canUndo`, `undoLimitExplanation`).
    @discardableResult
    func undo() async throws -> AudioEditEntry? {
        guard list.canUndo else { return nil }
        let file = audioFile
        let (list, entry) = try await Self.changeHistory(place: place) { history in
            var list = history.listOrNew(for: file)
            let entry = list.undo(at: Date())
            history.setList(list)
            return (list, entry)
        }
        try await adopt(list)
        return entry
    }

    /// Redoes the oldest undone edit and returns it; nil when none was undone.
    @discardableResult
    func redo() async throws -> AudioEditEntry? {
        guard list.canRedo else { return nil }
        let file = audioFile
        let (list, entry) = try await Self.changeHistory(place: place) { history in
            var list = history.listOrNew(for: file)
            let entry = list.redo(at: Date())
            history.setList(list)
            return (list, entry)
        }
        try await adopt(list)
        return entry
    }

    /// Gives the book an original policy of its own, or, for nil, has it
    /// follow the global setting again; the library applies it at once.
    func setPolicyOverride(_ policy: AudioOriginalPolicy?) async throws {
        guard let library else { throw AudioEditError.bookNotInLibrary }
        try await library.setAudioOriginalPolicy(policy, forBook: bookID)
        policyOverride = policy
    }

    // MARK: Previewing and Saving

    /// A composition of the edited audio, for an `AVPlayer` to play
    /// sample-exact: the window's preview. Each call makes a new one, which
    /// the caller owns and may hand to any actor.
    func makePreview() async throws -> sending AudioEditComposition {
        try await AudioEditComposition.make(
            timeline,
            sources: AudioEditComposition.Sources(base: base, package: place.package, scratch: scratch)
        )
    }

    /// Saves the edits into the book's file (`LibraryViewModel.saveAudioEdits`),
    /// telling `progress` how far it is, then reads the history and the
    /// audio the edits start from again: without an original, that is the
    /// file just saved.
    @discardableResult
    func save(progress: (@Sendable (Double) -> Void)? = nil) async throws -> AudioEditSaveOutcome {
        guard let library else { throw AudioEditError.bookNotInLibrary }
        let outcome = try await library.saveAudioEdits(ofBook: bookID, audioFile: audioFile, progress: progress)
        audioFile = outcome.audioFile
        let file = audioFile
        let (list, policy) = try await Self.changeHistory(place: place) { history in
            (history.listOrNew(for: file), history.policyOverride)
        }
        policyOverride = policy
        base = try await Self.loadBase(of: list, place: place)
        processor = makeProcessor(AudioEditComposition.Sources(base: base, package: place.package, scratch: scratch))
        timelines = [:]
        try await adopt(list)
        return outcome
    }

    /// Ends the session: its use of the book ends, and its scratch folder is
    /// removed.
    func close() {
        lease.end()
        AudioEditScratch.remove(for: bookID)
    }

    // MARK: Keeping the Timeline

    /// Takes `newList`, the list as the history now holds it, with the
    /// timeline it leaves the audio as: `expected`, worked out from `before`,
    /// when the list is `before` with one edit more; otherwise from the cache
    /// or by applying the list again.
    private func adopt(_ newList: AudioEditList, expecting expected: AudioEditTimeline? = nil, after before: AudioEditList? = nil) async throws {
        let key = Self.key(of: newList)
        let next: AudioEditTimeline
        if let expected, let before, Array(newList.entriesOverBase.dropLast()) == Array(before.entriesOverBase) {
            next = expected
        } else if let cached = timelines[key] {
            next = cached
        } else {
            next = try await Self.timeline(of: newList, over: base, processor: processor)
        }
        timelines[key] = next
        list = newList
        timeline = next
    }

    /// The cache key of `list`'s state: its newest applied edit over the
    /// base, or "" for none.
    private static func key(of list: AudioEditList) -> String {
        list.entriesOverBase.last?.id.uuidString ?? ""
    }

    // MARK: Helpers

    /// The timeline `list` leaves `base` as.
    private static func timeline(
        of list: AudioEditList,
        over base: AudioEditBase,
        processor: (any AudioEditProcessing)?
    ) async throws -> AudioEditTimeline {
        var timeline = base.timeline
        for entry in list.entriesOverBase {
            try await timeline.apply(entry.edit, processor: processor)
        }
        return timeline
    }

    /// The audio `list`'s edits start from: its original, or the book's file
    /// as last rendered.
    private static func loadBase(of list: AudioEditList, place: AudioBookPlace) async throws -> AudioEditBase {
        let file = list.original?.file ?? list.audioFile
        guard let url = AudioEditPackage.url(of: file, in: place.package) else { throw AudioEditError.fileOutsidePackage }
        return try await AudioEditBase.load(url, name: file)
    }

    /// How long the audio file at `url` lasts, in seconds.
    private static func length(of url: URL) async throws -> TimeInterval {
        try await OffMainWork.runThrowing {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        }
    }

    /// Changes the book's history with `change`, off the main thread, as
    /// storage work, and returns what it returns.
    private static func changeHistory<Result: Sendable>(
        place: AudioBookPlace,
        startingOver: Bool = false,
        _ change: @escaping @Sendable (inout AudioEditHistory) throws -> Result
    ) async throws -> Result {
        try await OffMainWork.runThrowing {
            try StorageBoundary.shared.perform(.audioEditing) { _ in
                try AudioEditHistoryStore.update(package: place.package, bookFile: place.bookFile, startingOver: startingOver, change)
            }
        }
    }
}
