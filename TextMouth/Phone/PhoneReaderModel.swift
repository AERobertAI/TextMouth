import Combine
import Foundation

/// The iPhone reader's model: what its controls say, read from the open
/// book's reader when VoiceOver asks, and the one path every move takes (the
/// spec, under "The reader" and "What a move says"; the engineering review's
/// F2 and F15).
///
/// - **Words when asked.** `state` is built from the reader's real cursor
///   (`currentChapterIndex`, `currentCharacterOffset`, not the throttled
///   display mirrors) once per turn of the main queue, however many times
///   VoiceOver asks for a label, a value, a hint, or traits. A change the
///   model makes itself clears it at once, so VoiceOver reads the new value
///   after an adjustment, not the old.
/// - **One move path.** Adjusting Play, the skip buttons, the heading
///   buttons, and the AirPods (`ReaderPhoneHooks`) all move through
///   `move(on:forward:unit:source:)`: Where Am I? is cancelled first, the
///   reader's own `performSkip(unit:forward:)` moves without the Mac's skip
///   debounce, what the shared code says is collected, and
///   `PhoneMoveFeedback` decides what Play's value holds and what's said.
/// - **Nothing focusable changes by itself.** Nothing here is published: a
///   view reads it, and VoiceOver's own reads see the words of the moment.
///
/// Shared, and naming no UIKit, so the Mac's test host runs its tests.
@MainActor
final class PhoneReaderModel {
    /// Collects what the shared code announces while `body` runs, instead of
    /// posting it.
    typealias Collector = @MainActor (_ body: () -> Void) -> [VoiceOverAnnouncement]
    /// Runs `work` after `delay` seconds, as `PhoneAnnouncer.schedule` does.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void

    // MARK: - What It Works With

    /// The reader on the screen: the session's open book, or nil.
    private let currentReader: @MainActor () -> ReaderViewModel?
    /// Plays or pauses the screen's book, as the session does.
    private let playOrPause: @MainActor () -> Void
    /// Plays the screen's book, leaving one that plays as it is.
    private let play: @MainActor () -> Void
    /// Where Settings keeps what a book of each kind moves by until it has a
    /// unit of its own (`PhoneDefaults`).
    private let preferences: UserDefaults
    /// Collects what a move or a change says.
    private let collect: Collector
    /// Posts an announcement.
    private let post: @MainActor (VoiceOverAnnouncement) -> Void
    /// Waits before an answer is posted.
    private let schedule: Scheduler
    /// Tells the session the book has been engaged, at its first move, so a
    /// mistaken double-tap on a row leaves New and Unopened as they were.
    private let noteEngaged: @MainActor () -> Void

    // MARK: - What It Holds

    /// The state built this turn of the main queue, until the next.
    private var cachedState: PhoneReaderState?
    /// What the last paused move said, for the book it was said in: Play's
    /// value until Play or the next move.
    private var moveWords: (bookID: UUID, words: String)?
    /// The readers the session publishes, heard to fill each one's hooks.
    private var readerSubscription: AnyCancellable?

    /// Told after the place of the screen's book has moved by the model's own
    /// doing, so Book content can follow a paused move
    /// (`PhonePassagePolicy.Event.movedWhilePaused`). One listener: the
    /// reader's text.
    var placeDidMove: (@MainActor () -> Void)?

    /// A model for the readers `readers` publishes, the one on screen being
    /// `currentReader`'s.
    ///
    /// - Parameters:
    ///   - currentReader: The reader on the screen, or nil.
    ///   - readers: Each reader as it's made, to fill its hooks.
    ///   - playOrPause: Plays or pauses the screen's book.
    ///   - preferences: Where Settings keeps each kind's unit.
    ///   - collect: Collects announcements; by default the foundation's
    ///     `VoiceOverAnnouncer.collectingAnnouncements(during:)`.
    ///   - post: Posts one announcement; by default through the shared
    ///     announcer, at its own priority.
    ///   - schedule: Waits; by default as `PhoneAnnouncer` does.
    ///   - noteEngaged: Tells the session of a first move on the screen's
    ///     book.
    init(
        currentReader: @escaping @MainActor () -> ReaderViewModel?,
        readers: AnyPublisher<ReaderViewModel?, Never>,
        playOrPause: @escaping @MainActor () -> Void,
        play: @escaping @MainActor () -> Void = {},
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        collect: @escaping Collector = { body in VoiceOverAnnouncer.collectingAnnouncements(during: body) },
        post: @escaping @MainActor (VoiceOverAnnouncement) -> Void = PhoneReaderModel.postThroughAnnouncer,
        schedule: @escaping Scheduler = { delay, work in PhoneAnnouncer.schedule(delay, work) },
        noteEngaged: @escaping @MainActor () -> Void = {}
    ) {
        self.currentReader = currentReader
        self.playOrPause = playOrPause
        self.play = play
        self.preferences = preferences
        self.collect = collect
        self.post = post
        self.schedule = schedule
        self.noteEngaged = noteEngaged
        readerSubscription = readers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reader in
                // Delivered on the main queue, as `receive(on:)` asks.
                MainActor.assumeIsolated {
                    guard let self, let reader else { return }
                    self.fillHooks(of: reader)
                }
            }
        if let reader = currentReader() {
            fillHooks(of: reader)
        }
    }

    /// A model for `session`'s readers: the one on screen, and the one
    /// listened to behind it, whose AirPods' moves take the phone's path
    /// too. It holds the session weakly: the session lives as long as the
    /// app does, and the model must never keep it.
    convenience init(session: PhoneSession) {
        self.init(
            currentReader: { [weak session] in session?.reader },
            readers: session.$reader.merge(with: session.$listeningReader).eraseToAnyPublisher(),
            playOrPause: { [weak session] in session?.togglePlayPause() },
            play: { [weak session] in session?.play() },
            noteEngaged: { [weak session] in session?.noteBookEngaged() }
        )
    }

    // MARK: - The One Model per Session

    /// The models made for each session, by its identity: the app has one
    /// session, and so one model, for as long as it runs.
    private static var models: [ObjectIdentifier: PhoneReaderModel] = [:]

    /// The one model for `session`, made the first time it's asked for. The
    /// app asks once the session exists, so the AirPods' moves take the
    /// phone's path before the reader's screen has ever shown; the reader's
    /// screen asks again and gets the same model.
    static func attached(to session: PhoneSession) -> PhoneReaderModel {
        let key = ObjectIdentifier(session)
        if let model = models[key] {
            return model
        }
        let model = PhoneReaderModel(session: session)
        models[key] = model
        return model
    }

    // MARK: - Reading the State

    /// The reader on the screen: the session's open book.
    var reader: ReaderViewModel? {
        currentReader()
    }

    /// Everything the controls say now, or nil with no book open. Built once
    /// per turn of the main queue.
    var state: PhoneReaderState? {
        if let cachedState {
            return cachedState
        }
        guard let reader else { return nil }
        let built = buildState(of: reader)
        cachedState = built
        // Kept until the main queue's next turn: VoiceOver's several reads
        // for one focus see one state, and the next focus a fresh one.
        DispatchQueue.main.async { [weak self] in
            self?.cachedState = nil
        }
        return built
    }

    /// What VoiceOver reads of `control` now; nil with no book open.
    func description(of control: PhoneReaderControl) -> PhoneControlDescription? {
        state.map { PhoneReaderControls.description(of: control, in: $0) }
    }

    /// Forgets the state built this turn, after a change, so the next read
    /// sees it.
    func invalidate() {
        cachedState = nil
    }

    /// The unit `reader`'s moves go by.
    func unitInForce(of reader: ReaderViewModel) -> SkipUnit {
        PhoneDefaults.navigationUnit(
            ownRawValue: reader.book.localSkipForwardUnit ?? reader.book.localSkipBackwardUnit,
            isAudio: reader.isAudioBook,
            offered: offeredUnits(of: reader),
            in: preferences
        )
    }

    /// The units `reader`'s book offers.
    func offeredUnits(of reader: ReaderViewModel) -> [SkipUnit] {
        PhoneNavigationUnits.offered(isAudioBook: reader.isAudioBook, hasSeveralPages: reader.hasSeveralPages)
    }

    /// The state of `reader` now, from its real cursor and its services'
    /// own flags, which change at once, where the published mirrors catch up
    /// a turn later.
    private func buildState(of reader: ReaderViewModel) -> PhoneReaderState {
        let isPlaying = reader.isPlaybackUnderWay
        // A book that has played since the last paused move has had its
        // Play: the move's words are no longer the answer.
        if isPlaying, moveWords?.bookID == reader.book.id {
            moveWords = nil
        }
        let position = reader.currentHeadingPosition
        return PhoneReaderState(
            bookTitle: reader.book.title,
            isLoading: reader.isLoading,
            loadFailure: reader.loadErrorMessage,
            isPlaying: isPlaying,
            isAudioBook: reader.isAudioBook,
            hasTranscript: reader.content?.transcript != nil,
            unit: unitInForce(of: reader),
            moveWords: moveWords?.bookID == reader.book.id ? moveWords?.words : nil,
            isWhereAmISpeaking: reader.isWhereAmISpeaking,
            whereAmI: whereAmIParts(of: reader, at: position),
            wordsPerMinute: reader.speechService.wordsPerMinute,
            audioSpeed: reader.audioSpeed,
            isNearBookmark: reader.hasNearbyBookmark,
            bookmarkCount: reader.bookmarks.count,
            headingPosition: position,
            sleepTimerStatus: reader.sleepTimerService.spokenStatus
        )
    }

    /// Where Am I?'s parts for `reader` at `position`: the page only while
    /// the reader screen's page setting is on and the book has pages to
    /// count; an audiobook's place in its recording.
    private func whereAmIParts(of reader: ReaderViewModel, at position: HeadingPosition) -> PhoneWhereAmIParts {
        let chapter = reader.currentChapterIndex
        let offset = reader.currentCharacterOffset
        let showsPage = reader.settingsViewModel.showsPageInReader && reader.hasSeveralPages
        return PhoneWhereAmIParts(
            heading: reader.locationTitle(for: position, chapterIndex: chapter),
            remainingInHeading: reader.content.flatMap { content in
                position.heading.flatMap { reader.remainingTime(inHeading: $0, content: content) }
            },
            pageLabel: showsPage ? reader.currentPagePosition.label : "",
            timeIntoRecording: reader.isAudioBook
                ? reader.placeClock?.time(chapterIndex: chapter, characterOffset: offset)
                : nil,
            percentComplete: reader.percentComplete,
            timeRemaining: reader.timeRemaining,
            speed: reader.namedListeningSpeed,
            isFinished: reader.cursorRestsAtEnd
        )
    }

    // MARK: - Moving

    /// Moves `reader` back or forward, by `unit` or the unit in force, and
    /// says what the move says. The one path every move on the phone takes.
    ///
    /// The Mac's 0.4-second skip debounce doesn't apply: it's for one media
    /// key arriving by two paths on a Mac, and it would drop a quick second
    /// flick in silence. Nor does the Mac's skip sound play: the phone has no
    /// sounds yet (the spec, under "The stand-ins that must become real").
    ///
    /// - Parameters:
    ///   - reader: The reader to move: the screen's for its controls, the
    ///     one whose hooks were called for the AirPods.
    ///   - forward: Whether to move forward.
    ///   - unit: The unit, or nil for the unit in force, as Next Heading
    ///     gives Heading whatever unit is in force.
    ///   - source: Where the move came from, which decides whether a paused
    ///     move's words are announced as well as put in Play's value.
    /// - Returns: Whether the place changed.
    @discardableResult
    func move(on reader: ReaderViewModel, forward: Bool, unit: SkipUnit? = nil, source: PhoneMoveFeedback.Source) -> Bool {
        guard !reader.isLoading, !reader.hasClosed, reader.content != nil else { return false }
        let unit = unit ?? unitInForce(of: reader)
        // Time-based skips don't cancel Where Am I? by themselves.
        reader.cancelWhereAmIIfActive()
        let before = (reader.currentChapterIndex, reader.currentCharacterOffset)
        let collected = collect {
            reader.performSkip(unit: unit, forward: forward)
        }
        let after = (reader.currentChapterIndex, reader.currentCharacterOffset)
        // A first move engages the book on screen; the book listened to
        // behind it, which the AirPods move, has played already.
        if reader === currentReader() {
            noteEngaged()
        }

        let feedback = PhoneMoveFeedback.deciding(PhoneMoveFeedback.Move(
            unit: unit,
            forward: forward,
            source: source,
            moved: before != after,
            isPlayingAfter: reader.isPlaybackUnderWay,
            isAudioBook: reader.isAudioBook,
            collected: collected,
            sentenceAtPlace: reader.isAudioBook ? nil : sentenceAtPlace(of: reader),
            timeAtPlace: reader.isAudioBook
                ? reader.placeClock?.time(chapterIndex: after.0, characterOffset: after.1)
                : nil
        ))
        moveWords = feedback.playValue.map { (bookID: reader.book.id, words: $0) }
        invalidate()
        if reader === currentReader() {
            placeDidMove?()
        }
        announceLater(feedback.announcements)
        return before != after
    }

    /// Moves the screen's reader: what adjusting Play, the skip buttons, and
    /// the heading buttons call.
    /// - Returns: Whether the place changed.
    @discardableResult
    func moveOnScreen(forward: Bool, unit: SkipUnit? = nil, source: PhoneMoveFeedback.Source) -> Bool {
        guard let reader else { return false }
        return move(on: reader, forward: forward, unit: unit, source: source)
    }

    /// The units Play's rotors move by, in the spec's order: Headings in a
    /// book with headings, Pages in a book of more than one page, Bookmarks
    /// in a book with one or more (the spec, under "The rotors").
    var playRotorUnits: [SkipUnit] {
        guard let reader else { return [] }
        var units: [SkipUnit] = []
        if !reader.headings.isEmpty { units.append(.heading) }
        if reader.hasSeveralPages { units.append(.page) }
        if !reader.bookmarks.isEmpty { units.append(.bookmark) }
        return units
    }

    /// The words from `reader`'s place to the end of their sentence.
    private func sentenceAtPlace(of reader: ReaderViewModel) -> String? {
        guard let chapters = reader.content?.chapters,
              chapters.indices.contains(reader.currentChapterIndex) else { return nil }
        return PhoneReaderWording.sentence(
            in: chapters[reader.currentChapterIndex].text,
            from: reader.currentCharacterOffset
        )
    }

    /// Gives `reader` the phone's move path for the system's skips: the
    /// AirPods' double and triple press, and Control Center's buttons. They
    /// capture the reader weakly, which holds them, and the model weakly.
    private func fillHooks(of reader: ReaderViewModel) {
        #if os(iOS)
        reader.phoneHooks.moveForward = { [weak self, weak reader] in
            guard let self, let reader else { return }
            self.move(on: reader, forward: true, source: .command)
        }
        reader.phoneHooks.moveBackward = { [weak self, weak reader] in
            guard let self, let reader else { return }
            self.move(on: reader, forward: false, source: .command)
        }
        // The lock screen's skip intervals follow the unit a move goes by.
        reader.phoneHooks.unitInForce = { [weak self, weak reader] in
            guard let self, let reader else { return PhoneDefaults.textNavigationUnitDefault }
            return self.unitInForce(of: reader)
        }
        #endif
    }

    // MARK: - Play

    /// Plays or pauses the screen's book, as the session does: a press while
    /// it loads waits for the load. Play's value after a move is forgotten.
    func togglePlayPause() {
        moveWords = nil
        playOrPause()
        invalidate()
    }

    // MARK: - Navigation Unit and Speed

    /// Adjusts Navigation unit to the next offered unit, or the one before,
    /// wrapping around. VoiceOver reads the new value alone: the shared
    /// "Navigation unit: Sentence" isn't also posted.
    func adjustUnit(up: Bool) {
        guard let reader else { return }
        choose(PhoneNavigationUnits.unit(after: unitInForce(of: reader), up: up, in: offeredUnits(of: reader)))
    }

    /// Makes `unit` the screen's book's own unit, for both directions, as the
    /// Mac's One Unit for Both Directions does, saying nothing.
    func choose(_ unit: SkipUnit) {
        guard let reader else { return }
        _ = collect {
            reader.setSharedPlaybackSkipUnit(unit)
        }
        invalidate()
    }

    /// Adjusts the screen's book's speed by the Mac's step: 25 words per
    /// minute, or 0.1 times for an audiobook. VoiceOver reads the new value
    /// alone: the shared "225 words per minute" isn't also posted.
    func adjustSpeed(up: Bool) {
        guard let reader, !reader.isLoading else { return }
        _ = collect {
            reader.stepSpeed(forward: up)
        }
        invalidate()
    }

    // MARK: - Answers to What the Listener Asked

    /// Speaks the Mac's brief Where Am I? summary in the book's voice, or
    /// stops it while it speaks.
    func whereAmI() {
        reader?.whereAmI(.brief)
        invalidate()
    }

    /// Speaks the Mac's full summary: Where Am I?'s first action.
    func whereAmIFullSummary() {
        reader?.whereAmI(.full)
        invalidate()
    }

    /// Copies the reading position, saying so: Where Am I?'s second action.
    func copyReadingPosition() {
        answer { $0.copyReadingPosition() }
    }

    /// The bookmark at the place that has a note, which Add bookmark asks
    /// about before removing; nil when there's none, or it has no note.
    var bookmarkToConfirmRemoving: Bookmark? {
        guard let reader,
              let bookmark = reader.nearbyBookmark(
                  chapterIndex: reader.currentChapterIndex,
                  characterOffset: reader.currentCharacterOffset
              ),
              bookmark.label.nonBlank != nil else { return nil }
        return bookmark
    }

    /// Adds a bookmark at the place, or removes the one there, saying the
    /// Mac's "Bookmark 3 added" or "Bookmark 3 removed", also while the book
    /// plays, since the listener asked.
    func toggleBookmark() {
        answer { $0.toggleBookmarkAtCurrentPosition() }
    }

    /// Goes back to where the last jump began, saying the Mac's "Returned to
    /// previous position", or "No previous position to return to."
    func returnToPreviousPlace() {
        answer { $0.goBack() }
        placeDidMove?()
    }

    // MARK: - Search in Book

    /// Search in Book was activated. True when the book has text to search
    /// and the sheet should open. Otherwise the listener is told why, a
    /// moment later as every answer is, and false is returned, so the
    /// button stays in its place and does something every time
    /// (the spec's "Everything else follows in a fixed order and a fixed
    /// place"):
    /// - while the book loads, "Loading Moby-Dick";
    /// - for an audiobook with no transcript text, the Mac's words for why
    ///   (`ReaderViewModel.announceNoTextToSearch`) without any that tell the
    ///   listener to transcribe, since the phone has no Transcribe Audio;
    /// - for a text book that failed to load, nothing: its screen shows the
    ///   failure in place of the controls.
    func openSearch() -> Bool {
        guard let reader else { return false }
        if reader.canSearchText { return true }
        if reader.isLoading {
            announceLater([VoiceOverAnnouncement(
                message: PhoneReaderVocabulary.loading(reader.book.title),
                priority: .medium
            )])
        } else if reader.isAudioBook {
            answer {
                $0.announceNoTextToSearch(
                    hasTranscript: TranscribedBooks.shared.contains($0.book.id),
                    offersTranscription: false
                )
            }
        }
        return false
    }

    /// Listen from Here: moves the screen's book to `offset` in chapter
    /// `chapterIndex`, keeping the old place for Return, and plays it. What
    /// the jump says is collected and dropped: the book, starting there, is
    /// the answer. Engages the book, as reading it has.
    func listen(fromChapter chapterIndex: Int, offset: Int) {
        guard let reader, !reader.isLoading, reader.content != nil else { return }
        moveWords = nil
        _ = collect {
            reader.navigatePreservingReturnPosition(chapterIndex: chapterIndex, characterOffset: offset)
        }
        noteEngaged()
        play()
        invalidate()
    }

    /// Book content took focus: the book counts as opened, as reading it has.
    func noteReading() {
        noteEngaged()
    }

    /// A sheet (Headings, Bookmarks, Go To) moved the book: it counts as
    /// opened, as any move does, so Back doesn't close it as one opened by
    /// mistake and drop the jump's place.
    func noteJumped() {
        noteEngaged()
    }

    /// Moves the screen's paused book to `offset` in chapter `chapterIndex`
    /// as a page of Book content is turned, keeping the old place for
    /// Return, and saying nothing: the page's own status says where.
    func turnPage(toChapter chapterIndex: Int, offset: Int) {
        guard let reader, !reader.isLoading, reader.content != nil else { return }
        moveWords = nil
        _ = collect {
            reader.navigatePreservingReturnPosition(chapterIndex: chapterIndex, characterOffset: offset)
        }
        noteEngaged()
        invalidate()
    }

    /// Runs `body` on the screen's reader, and says what it said a moment
    /// later, so the activation's own sounds don't cut it off.
    private func answer(_ body: (ReaderViewModel) -> Void) {
        guard let reader else { return }
        let collected = collect {
            body(reader)
        }
        invalidate()
        announceLater(collected)
    }

    /// Posts `announcements` as one announcement, in order, after
    /// `PhoneAnnouncer.delay`, the spec's 0.15 seconds, so SwiftUI's own layout
    /// notification after an activation doesn't cut it off. They're joined
    /// because posted one by one, each would interrupt (or queue behind) the
    /// one before it, and only the last would be heard.
    private func announceLater(_ announcements: [VoiceOverAnnouncement]) {
        guard let combined = PhoneAnnouncer.combined(announcements) else { return }
        let post = post
        schedule(PhoneAnnouncer.delay) {
            post(combined)
        }
    }

    /// Posts `announcement` through the shared announcer, at its priority.
    static func postThroughAnnouncer(_ announcement: VoiceOverAnnouncement) {
        VoiceOverAnnouncer.announce(announcement.message, priority: announcement.priority)
    }
}
