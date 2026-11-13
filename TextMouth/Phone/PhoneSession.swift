import Combine
import Foundation

/// The owner of the iPhone's open readers, above the navigation: leaving a
/// reader's screen never closes a book by itself, as a Mac window's closing
/// does, so a book plays on in the Library and with the screen locked.
///
/// Two readers at most, by the user's review (finding 3): opening book B while
/// book A is open makes B and leaves A alone, playing or not. B is the reader
/// on screen (`reader`), and A goes on in the background (`listeningReader`),
/// and stays in the Continue row. When B plays, the shared code pauses A, as
/// every start passes through `NowPlayingService.prepareForPlayback`, and the
/// session closes A: B is then the one reader. Leaving B's screen before B has
/// played closes B, and A is as it was. So a mistaken double-tap on a row
/// stops nothing, and Back undoes it.
///
/// It compiles on the Mac too, where only the tests reach it, and it names no
/// UIKit. The Mac's own app never makes one.
@MainActor
final class PhoneSession: ObservableObject {
    // MARK: - The Preferences

    /// The book to open again at the next launch: the one in reach as the app
    /// last left the screen. Written as it changes, never at the end, since iOS
    /// may end a suspended app without a word.
    nonisolated static let reopenBookKey = "phone.reopenBookID"
    /// Whether that book's reader was on screen as the app left the foreground.
    nonisolated static let reopenShowsReaderKey = "phone.reopenShowsReader"
    /// Whether that book was being read from the Reading List.
    nonisolated static let reopenFromReadingListKey = "phone.reopenFromReadingList"
    /// The book whose reader is being made and loaded. Written before the
    /// reader is made and removed once its load ends: still there at launch, it
    /// says the app ended while opening that book, which is then not opened by
    /// itself again, so a book that crashes on loading cannot do so at every
    /// launch (the engineering review's F4).
    nonisolated static let openingBookKey = "phone.openingBookID"

    // MARK: - What Screens Read

    /// The reader on screen, or, with no screen showing one, the one reader
    /// open. A view calls it and reads `snapshot` for what it shows: observing
    /// the reader itself would rebuild the view eight times a second while the
    /// book plays.
    @Published private(set) var reader: ReaderViewModel?
    /// The book that goes on behind `reader`'s, playing or paused: the one open
    /// when the listener opened `reader`'s, until `reader` plays or is left.
    @Published private(set) var listeningReader: ReaderViewModel?
    /// What a screen shows of `reader`, changing only when a field does.
    @Published private(set) var snapshot: PhoneReaderSnapshot?
    /// What a screen shows of `listeningReader`.
    @Published private(set) var listeningSnapshot: PhoneReaderSnapshot?
    /// Whether a press of Play waits for `reader`'s book to finish loading: a
    /// reader ignores Play while it loads, and the listener should not have to
    /// find Play twice (F9). Set by Play, the magic tap, or a remote Play during
    /// loading, cleared by a second press, and taken as loading ends.
    private(set) var playWhenLoaded = false

    /// What the Continue row shows: the book that goes on behind the one on
    /// screen, else the one reader.
    var continueSnapshot: PhoneReaderSnapshot? {
        listeningSnapshot ?? snapshot
    }

    /// Tells the navigation to show the reader's screen, with the book's ID:
    /// a book opened by something other than its row, such as an import that
    /// opens what it added. Going on to the next book sends nothing: a
    /// listener in the Library stays there.
    let showReaderRequests = PassthroughSubject<UUID, Never>()

    /// Tells of each reader once, as the session makes it, before anything can
    /// play it and whichever slot it takes. The parts of the phone that give a
    /// reader its hooks (the audio session, the life cycle's background hold)
    /// join here, so that none can miss a reader that goes straight behind the
    /// screen, as the next book of a hand-over does.
    let readerMade = PassthroughSubject<ReaderViewModel, Never>()

    /// Begins a hold that keeps the app running for work the system must let
    /// finish, and returns what ends it: `PhoneAppModel` passes its life
    /// cycle's, a background task on iOS.
    var beginHold: @MainActor (_ name: String) -> (@MainActor () -> Void) = { _ in {} }

    // MARK: - What It Works With

    /// Makes a reader for a book, given the library's row: the app's way, or a
    /// test's, whose readers use its own notification center and media session.
    typealias ReaderMaker = @MainActor (Book) -> ReaderViewModel

    /// The library the books come from.
    let library: LibraryViewModel
    /// Plays each reader's sounds.
    private let soundEffects: SoundEffectService
    /// Makes each reader.
    private let makeReader: ReaderMaker
    /// Where a finished book asks the next one to start playing.
    private let autoplayRequests: ReaderAutoplayRequests
    /// The preferences that keep what is reopened, and the book being opened.
    private let preferences: UserDefaults
    /// The configuration whose last opened book a reader records as it opens.
    private let config: ConfigService

    /// The book that was being opened when the app last ended, read and cleared
    /// as the session is made, which is at launch, before any reader exists.
    /// Read there rather than at the first activation, since a lock-screen Play
    /// that wakes the app opens a book first, and its own mark would be taken
    /// for a crash. `takeReopeningAtLaunch` acts on it.
    private var openingBookAtLastEnd: String?

    /// The reader `reader` is, with what is followed of it.
    private var current: OpenReader?
    /// The reader `listeningReader` is, with what is followed of it.
    private var listening: OpenReader?
    /// The app-wide requests to open a book, heard while the session lasts.
    private var booksAskedForSubscription: AnyCancellable?

    /// A session over the app's stores, or a test's.
    ///
    /// - Parameters:
    ///   - notificationCenter: Where readers post the books they ask for: the
    ///     app's, or a test's, so that the running app's windows never hear it.
    ///   - autoplayRequests: Where a finished book's request for the next one
    ///     waits. Nil uses the shared store, read here rather than as a default
    ///     argument, inside this main-actor initializer, as `ReaderViewModel`
    ///     does.
    ///   - preferences: Keeps what is reopened.
    ///   - config: Nil uses the shared configuration, which every reader writes.
    ///   - makeReader: Makes each reader; nil makes the app's, over
    ///     `notificationCenter` and `autoplayRequests`.
    init(
        library: LibraryViewModel,
        settings: SettingsViewModel,
        soundEffects: SoundEffectService,
        notificationCenter: NotificationCenter = .default,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        config: ConfigService? = nil,
        makeReader: ReaderMaker? = nil
    ) {
        let requests = autoplayRequests ?? .shared
        // Before anything can write its own mark (`openingBookKey`).
        openingBookAtLastEnd = preferences.string(forKey: Self.openingBookKey)
        preferences.removeObject(forKey: Self.openingBookKey)
        // The reopen keys go with the guard, in the same breath: the guard is
        // gone from disk now, so a crash before the first activation
        // (`takeReopeningAtLaunch`) must not find the keys still naming the
        // book the app ended opening, and open it again at the next launch.
        // The verdict stays in `openingBookAtLastEnd`.
        if openingBookAtLastEnd != nil {
            Self.forgetReopening(in: preferences)
        }
        self.library = library
        self.soundEffects = soundEffects
        self.autoplayRequests = requests
        self.preferences = preferences
        self.config = config ?? .shared
        self.makeReader = makeReader ?? { book in
            BookReaderWindowView.makeReader(
                book: book,
                libraryViewModel: library,
                settingsViewModel: settings,
                // No switcher: a reader with none goes on to the next book by
                // the notifications heard below, whatever the window setting.
                showBook: nil,
                requestedBookID: book.id,
                autoplayRequests: requests,
                notificationCenter: notificationCenter
            )
        }

        // An import that opens its book, or a feed's episode, opens it here.
        // The library holds this closure and the session holds the library, so
        // it captures the session weakly.
        library.readerOpener = { [weak self] bookID in
            guard let self, let book = self.library.bookByID(bookID) else {
                self?.refuse(bookID)
                return
            }
            self.open(book)
            self.showReaderRequests.send(bookID)
        }
        booksAskedForSubscription = Self.booksAskedFor(on: notificationCenter)
            .sink { [weak self] asked in
                // Delivered on the main queue, as `booksAskedFor(on:)` asks.
                MainActor.assumeIsolated {
                    self?.take(asked)
                }
            }
    }

    // MARK: - The App-Wide Requests

    /// The books the app asks to have opened on `center`. On the Mac only the
    /// window router hears these, through the app delegate; here the session is
    /// the app's one "window", and without this, Continue to Next Book says
    /// "Starting: Dune" and nothing starts.
    ///
    /// Nonisolated, so that the closures reading each notification belong to no
    /// actor: a notification reaches its observers on the thread that posted
    /// it, and a main-actor closure stops the app if run on another. Delivered
    /// on the main queue a turn after the post: the reader posting is partway
    /// through its own work (`showNextBook`), and closing it inside the post
    /// would pull it out from under that work.
    private nonisolated static func booksAskedFor(on center: NotificationCenter) -> AnyPublisher<BookAskedFor, Never> {
        let next = center.publisher(for: .continueToNextBook).compactMap { notification -> BookAskedFor? in
            guard let bookID = notification.nextBookID else { return nil }
            let previous = notification.userInfo?[Notification.ContinueToNextBookKey.previousBookID] as? UUID
            return .next(bookID, after: previous)
        }
        let open = center.publisher(for: .openBookWindow).compactMap { notification -> BookAskedFor? in
            (notification.object as? UUID).map(BookAskedFor.open)
        }
        return next.merge(with: open)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Takes one app-wide request.
    private func take(_ asked: BookAskedFor) {
        switch asked {
        case let .next(bookID, previous):
            goOn(to: bookID, after: previous)
        case let .open(bookID):
            guard let book = library.bookByID(bookID) else { return refuse(bookID) }
            open(book)
        }
    }

    /// Refuses a book that has left the library since it was asked for:
    /// nothing opens, and nothing is left waiting for it, neither its request
    /// to play nor a sleep timer, which would count toward pausing nothing.
    private func refuse(_ bookID: UUID) {
        DiagnosticLog.event(
            .app,
            "phone session: asked to open a book no longer in the library: \(bookID.uuidString.prefix(8))"
        )
        autoplayRequests.discard(for: bookID)
        SleepTimerRegistry.shared.releaseHeld(forBook: bookID)
    }

    // MARK: - Opening

    /// Opens `book` on screen: its reader when it is open already, and
    /// otherwise a new reader, at the book's place, not playing.
    ///
    /// The reader open now goes on behind it, playing or not, unless one is
    /// already there; then the one on screen gives way, as Back would. The
    /// book going on behind, if asked for, comes forward instead.
    ///
    /// - Parameter book: The book to open. The library's own row for it is what
    ///   the reader starts from, so a row a view read a while ago never opens
    ///   the book at an old place; a book no longer in the library is refused,
    ///   and never stood in for, as the Mac's window does for a missing book.
    /// - Returns: The book's reader, or nil when the book was refused.
    @discardableResult
    func open(_ book: Book) -> ReaderViewModel? {
        guard let row = library.bookByID(book.id) else {
            refuse(book.id)
            return nil
        }
        if let current, current.bookID == row.id, !current.reader.hasClosed {
            return current.reader
        }
        playWhenLoaded = false
        if let listening, listening.bookID == row.id {
            // The book behind comes forward; the one on screen gives way.
            if let current { close(current) }
            setListening(nil)
            setCurrent(listening)
            rememberForReopening()
            return listening.reader
        }
        if let current {
            if listening == nil {
                // The book open now goes on behind the new one.
                setListening(current)
            } else {
                close(current)
            }
        }
        let opened = makeOpenReader(for: row)
        setCurrent(opened)
        rememberForReopening()
        return opened.reader
    }

    /// Goes on from the book `previous` to the book `bookID`, as a finished
    /// book asks: the new reader takes the old one's place, and claims the
    /// request to play as it loads, as a reader does on the Mac.
    ///
    /// So that TextMouth stays the Now Playing app with the screen locked, the
    /// new reader is made first, given its item, paused, and only then is the
    /// old one closed: the old one's leaving shows the new item at once. The
    /// order the Mac has always run, its old window staying open while the new
    /// one opens (the engineering review's F1). A hold covers the time until the
    /// new book has loaded, should the app be in the background.
    private func goOn(to bookID: UUID, after previous: UUID?) {
        guard let book = library.bookByID(bookID) else { return refuse(bookID) }
        // A book open already claims its request itself.
        if current?.bookID == bookID || listening?.bookID == bookID { return }
        let replacesListening = previous != nil && listening?.bookID == previous
        let replacesCurrent = !replacesListening && previous != nil && current?.bookID == previous
        guard replacesListening || replacesCurrent else {
            open(book)
            return
        }
        let opened = makeOpenReader(for: book)
        opened.holdUntilLoaded(beginHold("Going on to the next book"))
        opened.reader.nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: false
        )
        if replacesListening, let old = listening {
            setListening(opened)
            close(old)
        } else if let old = current {
            setCurrent(opened)
            close(old)
        }
        rememberForReopening()
    }

    /// Makes the reader of `book`, with everything the session follows of it.
    /// The book being opened is written first, so that a crash in the making or
    /// the load is known at the next launch (`openingBookKey`).
    private func makeOpenReader(for book: Book) -> OpenReader {
        preferences.set(book.id.uuidString, forKey: Self.openingBookKey)
        let lastOpenedBookID = config.config.lastOpenedBookID
        let made = makeReader(book)
        // At once, not as a view appears: a Play from the AirPods, or a request
        // to play the book, may come first, and it plays a sound.
        made.soundEffectService = soundEffects
        let opened = OpenReader(
            reader: made,
            lastOpenedBefore: book.lastOpened,
            lastOpenedBookIDBefore: lastOpenedBookID
        )
        follow(opened)
        readerMade.send(made)
        return opened
    }

    // MARK: - Leaving and Closing

    /// The reader's screen was left, by Back or the scrub. A book open behind,
    /// with the one on screen never played, comes back as it was, and the one
    /// on screen closes. A book never played, moved, or read closes too: it
    /// was opened by mistake, and the Continue row must not name it. Any other
    /// book stays open, playing or not.
    func leaveReader() {
        // A book the listener pressed Play on while it loaded is about to play:
        // Back leaves it open.
        guard let current, !current.hasPlayed, !playWhenLoaded else { return }
        if let listening {
            close(current)
            setListening(nil)
            setCurrent(listening)
        } else if !current.isEngaged {
            close(current)
            setCurrent(nil)
        }
        rememberForReopening()
    }

    /// Saves and closes every open book: the one on screen and the one behind
    /// it. A closed reader is finished and never plays again, which is why
    /// nothing calls this from a view's disappearing.
    func closeReader() {
        if let listening {
            setListening(nil)
            close(listening)
        }
        if let current {
            setCurrent(nil)
            close(current)
        }
        rememberForReopening()
    }

    /// Saves and closes the reader of the book `bookID` alone, leaving the
    /// other open book as it was: for a book removed from the library while
    /// it is open behind the screen, which must not stop the other book that
    /// plays on. Nothing happens when the book is not open.
    ///
    /// When the book was the one on screen and another goes on behind it,
    /// that one comes forward, as it does when Back leaves an unplayed
    /// reader (`leaveReader`).
    func closeBook(id bookID: UUID) {
        if let behind = listening, behind.bookID == bookID {
            setListening(nil)
            close(behind)
        } else if let onScreen = current, onScreen.bookID == bookID {
            if let behind = listening {
                // Closed first, then the book behind takes its place, as in
                // `leaveReader`.
                close(onScreen)
                setListening(nil)
                setCurrent(behind)
            } else {
                setCurrent(nil)
                close(onScreen)
            }
        } else {
            return
        }
        rememberForReopening()
    }

    /// Closes `opened`: it is followed no more, it saves and closes, and, if
    /// the listener never engaged with its book, the book is left as it was:
    /// still "New", still unopened, and not among the recently opened, which a
    /// reader's own saving would otherwise change.
    private func close(_ opened: OpenReader) {
        opened.stopFollowing()
        endOpening(opened)
        opened.reader.close()
        guard !opened.isEngaged else { return }
        if library.bookByID(opened.bookID)?.lastOpened != opened.lastOpenedBefore {
            library.updateBook(id: opened.bookID) { $0.lastOpened = opened.lastOpenedBefore }
        }
        if config.config.lastOpenedBookID == opened.bookID.uuidString,
           opened.lastOpenedBookIDBefore != opened.bookID.uuidString {
            config.config.lastOpenedBookID = opened.lastOpenedBookIDBefore
            config.scheduleSave()
        }
    }

    /// `opened` is no longer being opened, because its load ended or it
    /// closed: its mark in the crash guard goes, if it is still the one
    /// written, and any hold begun for the wait ends.
    private func endOpening(_ opened: OpenReader) {
        if preferences.string(forKey: Self.openingBookKey) == opened.bookID.uuidString {
            preferences.removeObject(forKey: Self.openingBookKey)
        }
        opened.endHoldOnLoad?()
        opened.endHoldOnLoad = nil
    }

    /// Makes `opened` the reader on screen, publishing it and its snapshot, ending
    /// a press that waited for the book before it, and making it the target of
    /// a remote Play.
    private func setCurrent(_ opened: OpenReader?) {
        current = opened
        // A press that waited belonged to the book that was on screen.
        playWhenLoaded = false
        // One rule for which book a remote Play reaches: the one on screen,
        // as the magic tap does. Nothing else on iOS focuses a reader
        // (`NowPlayingSession.focus()`).
        opened?.reader.nowPlayingService.focus()
        reader = opened?.reader
        snapshot = opened?.latest
    }

    /// Makes `opened` the reader behind, publishing it and its snapshot.
    private func setListening(_ opened: OpenReader?) {
        listening = opened
        listeningReader = opened?.reader
        listeningSnapshot = opened?.latest
    }

    // MARK: - Engaging

    /// The listener engaged with the book on screen: its first Play, its first
    /// move, or Book content taking focus. Only then does the book count as
    /// opened, so a mistaken double-tap on a row leaves it as it was.
    func noteBookEngaged() {
        guard let current else { return }
        engage(current)
    }

    /// Counts `opened`'s book as opened, once.
    private func engage(_ opened: OpenReader) {
        guard !opened.isEngaged else { return }
        opened.isEngaged = true
        library.markBookOpened(opened.bookID)
    }

    // MARK: - Play and Pause

    /// Plays or pauses the book on screen, as its Play button does. A press
    /// while it loads waits for the load to end (`playWhenLoaded`), and a
    /// second one takes it back. While a finished book's request to play waits
    /// for it, the book is about to play, so the press means stop.
    func togglePlayPause() {
        guard let reader else { return }
        guard reader.isLoading else {
            reader.togglePlayPause()
            return
        }
        let bookID = reader.book.id
        if autoplayRequests.hasRequest(for: bookID) {
            autoplayRequests.discard(for: bookID)
            playWhenLoaded = false
        } else {
            playWhenLoaded.toggle()
            if playWhenLoaded { noteBookEngaged() }
        }
    }

    /// Plays the book on screen, as a remote Play does: now, or once it has
    /// loaded; a book playing is left as it is.
    func play() {
        guard let reader else { return }
        if reader.isLoading {
            playWhenLoaded = true
            noteBookEngaged()
        } else {
            reader.playOrResume()
        }
    }

    /// What the magic tap does, and the fallback of the remote commands: with
    /// anything audible, pauses it; from silence, plays the book on screen, or
    /// else the book in reach (`bookInReach`), opened where the listener is,
    /// and played once it has loaded, as a press of Play would, so a finished
    /// book says what Play says of it.
    ///
    /// - Returns: False when there is no book to play, so that the system's
    ///   own fallback runs.
    func togglePlayPauseFromAnywhere() -> Bool {
        if let audible = [listening, current].compactMap({ $0 }).first(where: { $0.reader.isPlaybackActivelyAdvancing }) {
            audible.reader.togglePlayPause()
            return true
        }
        if current != nil {
            togglePlayPause()
            return true
        }
        guard let book = bookInReach else { return false }
        // A Play that wakes a killed app opens the book in the background; the
        // app is held until it has loaded, as a hand-over's is (`goOn`).
        let endHold = beginHold("Playing from the lock screen")
        guard let opened = open(book) else {
            endHold()
            return false
        }
        if opened.isLoading, let holder = current {
            holder.holdUntilLoaded(endHold)
            playWhenLoaded = true
            noteBookEngaged()
        } else {
            endHold()
            opened.playOrResume()
        }
        return true
    }

    /// Pauses the book that plays, whichever of the two readers it is, for
    /// Preview Voice, and returns what plays it on (`PhonePreviewPause`), or
    /// nil when none plays. The pause is the reader's own, without its pause
    /// sound, since the preview is about to speak.
    func pauseBookForPreview() -> (@MainActor () -> Void)? {
        // The two may be one reader; it is paused once.
        var seen: [ObjectIdentifier] = []
        let readers = [listening, current].compactMap { $0?.reader }.filter { reader in
            let id = ObjectIdentifier(reader)
            defer { seen.append(id) }
            return !seen.contains(id)
        }
        return PhonePreviewPause.pause(readers.map { reader in
            PhonePreviewPause.Reader(
                isPlaying: { reader.isPlaybackActivelyAdvancing },
                pause: { reader.pause(playingPauseSound: false) },
                resume: { reader.playOrResume() }
            )
        })
    }

    /// Whether any open book plays, the one on screen or the one behind it.
    /// Both snapshots are read: with one book playing behind an unplayed one,
    /// the screen's snapshot alone says nothing plays.
    var isAnyBookPlaying: Bool {
        snapshot?.isPlaying == true || listeningSnapshot?.isPlaying == true
    }

    /// The book a press reaches with no reader to press: the open reader's
    /// book, else the book last opened, else the row opened most recently, else
    /// none.
    var bookInReach: Book? {
        if let open = listening ?? current, let book = library.bookByID(open.bookID) {
            return book
        }
        if let last = library.lastOpenedBook {
            return last
        }
        return library.library.books
            .filter { $0.lastOpened != nil }
            .max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
    }

    // MARK: - Following

    /// Follows `opened` for as long as it is open: a follower of its own reads
    /// the reader a turn of the main queue after each change, and tells only of
    /// a value that differs, so nothing here hears the reader's place move. A
    /// second subscription hears its load end.
    private func follow(_ opened: OpenReader) {
        let follower = ReaderSnapshot(of: opened.reader) { PhoneReaderSnapshot(of: $0) }
        opened.follower = follower
        opened.latest = follower.value
        follower.$value
            .sink { [weak self, weak opened] latest in
                guard let self, let opened else { return }
                self.readerChanged(opened, to: latest)
            }
            .store(in: &opened.subscriptions)
        opened.reader.$isLoading
            // Heard before the value is stored, and before the rest of the
            // load's end runs: read on the main queue's next turn, by which
            // time the reader has claimed any request to play.
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self, weak opened] _ in
                MainActor.assumeIsolated {
                    guard let self, let opened else { return }
                    self.loadEnded(opened)
                }
            }
            .store(in: &opened.subscriptions)
    }

    /// Publishes `latest`, `opened`'s snapshot. The first time its book plays,
    /// it counts as opened and played; and the book on screen playing closes
    /// the book behind it, which the start itself has paused.
    private func readerChanged(_ opened: OpenReader, to latest: PhoneReaderSnapshot) {
        opened.latest = latest
        if opened === current {
            snapshot = latest
        } else if opened === listening {
            listeningSnapshot = latest
        }
        guard latest.isPlaying, !opened.hasPlayed else { return }
        opened.hasPlayed = true
        engage(opened)
        if opened === current, let behind = listening {
            setListening(nil)
            close(behind)
            rememberForReopening()
        }
    }

    /// `opened`'s load ended, loaded or not: it is no longer being opened, a
    /// hand-over's hold ends, and a press of Play that waited plays the book on
    /// screen, if it loaded; one that failed has nothing to play.
    private func loadEnded(_ opened: OpenReader) {
        endOpening(opened)
        guard opened === current, playWhenLoaded else { return }
        playWhenLoaded = false
        guard opened.reader.loadErrorMessage == nil else { return }
        opened.reader.playOrResume()
    }

    // MARK: - Reopening

    /// Keeps the book in reach for the next launch, or, with none open, keeps
    /// nothing: the one behind the screen's when there is one, since the
    /// screen's has not been played.
    private func rememberForReopening() {
        guard let kept = listening ?? current else {
            forgetReopening()
            return
        }
        preferences.set(kept.bookID.uuidString, forKey: Self.reopenBookKey)
    }

    /// The app is leaving the foreground: keeps whether the reader's screen
    /// showing is the kept book's, and whether that book is read from the
    /// Reading List, so the next launch can open it as it was.
    func noteAppLeavingForeground(readerScreenShowing: Bool) {
        rememberForReopening()
        guard let kept = listening ?? current else { return }
        preferences.set(readerScreenShowing && kept === current, forKey: Self.reopenShowsReaderKey)
        preferences.set(kept.reader.isOpenedFromReadingList, forKey: Self.reopenFromReadingListKey)
    }

    /// The book kept for reopening, as the next launch would open it: none
    /// while the app ended opening a book, and none once that book has left the
    /// library. It changes nothing; `takeReopeningAtLaunch(fileOpened:)` does.
    var bookToReopenAtLaunch: Book? {
        guard openingBookAtLastEnd == nil,
              let saved = preferences.string(forKey: Self.reopenBookKey),
              let bookID = UUID(uuidString: saved) else { return nil }
        return library.bookByID(bookID)
    }

    /// What the app does at launch about the book open when it last ended,
    /// once: it clears what should not be tried again. A file opened at launch
    /// wins over reopening.
    func takeReopeningAtLaunch(fileOpened: Bool) -> PhoneLaunchReopening {
        if let opening = openingBookAtLastEnd {
            // The reopen keys were cleared when the guard was (in `init`); not
            // again here, since a book opened since then (a Play from the
            // lock screen) has written keys of its own, which stand.
            openingBookAtLastEnd = nil
            let title = UUID(uuidString: opening).flatMap { library.bookByID($0) }?.title
            return title.map { .closedWhileOpening(PhoneAppWording.closedWhileOpening($0)) } ?? .nothing
        }
        guard !fileOpened, let book = bookToReopenAtLaunch else {
            if !fileOpened { forgetReopening() }
            return .nothing
        }
        return .reopen(PhoneReopening(
            book: book,
            showsReaderScreen: preferences.bool(forKey: Self.reopenShowsReaderKey),
            readFromReadingList: preferences.bool(forKey: Self.reopenFromReadingListKey)
        ))
    }

    /// Keeps nothing to reopen.
    private func forgetReopening() {
        Self.forgetReopening(in: preferences)
    }

    /// Removes the three keys that name the book to reopen from `preferences`:
    /// the one place they are listed, so the session's instance and its `init`
    /// (which cannot call an instance method before it has finished) share it.
    private static func forgetReopening(in preferences: UserDefaults) {
        for key in [reopenBookKey, reopenShowsReaderKey, reopenFromReadingListKey] {
            preferences.removeObject(forKey: key)
        }
    }
}

// MARK: - A Book Asked For

/// A book the app asks to have opened, read from a notification on whatever
/// thread posted it, so it belongs to no actor.
private enum BookAskedFor: Sendable {
    /// The book after one that finished, to open and play (`.continueToNextBook`).
    case next(UUID, after: UUID?)
    /// A book to open without playing: Next in Folder's (`.openBookWindow`).
    case open(UUID)
}

// MARK: - An Open Reader

/// A reader the session holds, with what the session follows of it.
@MainActor
private final class OpenReader {
    /// The reader.
    let reader: ReaderViewModel
    /// Its book, as it opened.
    let bookID: UUID
    /// The book's last opening before this one, given back if the listener
    /// never engages with it.
    let lastOpenedBefore: Date?
    /// The last opened book the configuration named before this reader
    /// recorded its own, given back likewise.
    let lastOpenedBookIDBefore: String
    /// Reads the reader after each change, telling only of a value that
    /// differs.
    var follower: ReaderSnapshot<PhoneReaderSnapshot>?
    /// What the follower last told.
    var latest: PhoneReaderSnapshot
    /// What the session hears of the reader.
    var subscriptions = Set<AnyCancellable>()
    /// Whether the listener has engaged with the book: played it, moved in it,
    /// or read it.
    var isEngaged = false
    /// Whether the book has played since it opened.
    var hasPlayed = false
    /// Ends the holds begun for the wait until the book has loaded.
    var endHoldOnLoad: (@MainActor () -> Void)?

    /// Keeps `endHold`, to run once the book has loaded; a hold kept already
    /// ends too, so a book asked for twice during its load holds the app once
    /// for each and releases both.
    func holdUntilLoaded(_ endHold: @escaping @MainActor () -> Void) {
        let before = endHoldOnLoad
        endHoldOnLoad = {
            before?()
            endHold()
        }
    }

    init(reader: ReaderViewModel, lastOpenedBefore: Date?, lastOpenedBookIDBefore: String) {
        self.reader = reader
        bookID = reader.book.id
        self.lastOpenedBefore = lastOpenedBefore
        self.lastOpenedBookIDBefore = lastOpenedBookIDBefore
        latest = PhoneReaderSnapshot(of: reader)
    }

    /// Hears nothing more of the reader.
    func stopFollowing() {
        follower = nil
        subscriptions.removeAll()
    }
}

// MARK: - Reopening at Launch

/// A book to open again at launch, as it was when the app last left the screen.
struct PhoneReopening: Equatable {
    /// The book, opened paused at its place.
    let book: Book
    /// Whether its reader's screen was showing, and so is pushed again.
    let showsReaderScreen: Bool
    /// Whether it was being read from the Reading List.
    let readFromReadingList: Bool
}

/// What the app does at launch about the book open when it last ended.
enum PhoneLaunchReopening: Equatable {
    /// Nothing: no book was open, a file opened at launch comes first, or the
    /// book has left the library.
    case nothing
    /// Open this book again.
    case reopen(PhoneReopening)
    /// The app ended while opening a book, which is not opened again; say this,
    /// with low priority.
    case closedWhileOpening(String)
}
