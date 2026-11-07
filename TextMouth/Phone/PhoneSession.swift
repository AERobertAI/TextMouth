import Combine
import Foundation

/// The one owner of the open book's reader on the iPhone.
///
/// On the Mac a reader belongs to its window's view, which closes it as the
/// window goes. A phone has one screen, and leaving the reader's screen must
/// not stop the book: so the reader is owned here, above the navigation, and
/// no view's disappearing closes it. There is one reader at a time. Opening
/// another book saves and closes the first, and the new one waits at its place
/// until Play.
///
/// It compiles on the Mac too, where only the tests reach it, and it names no
/// UIKit. The Mac's own app never makes one.
@MainActor
final class PhoneSession: ObservableObject {
    /// The preference that holds the open book's ID while it is open, so that
    /// an app the system ended can open it again at the next launch.
    nonisolated static let openBookPreferenceKey = "phoneSession.openBookID"

    // MARK: - What Screens Read

    /// The open book's reader, or nil when no book is open. A view calls it,
    /// and reads `snapshot` for what it shows: observing the reader itself
    /// would rebuild the view eight times a second while the book plays.
    @Published private(set) var reader: ReaderViewModel?

    /// What a screen shows of the open book, or nil when no book is open. It
    /// changes only when a field of its own does.
    @Published private(set) var snapshot: PhoneReaderSnapshot?

    /// Tells the navigation to show the reader's screen, with the book's ID:
    /// a book opened by something other than its row, which has no way to
    /// push the screen itself, such as an import that opens what it added.
    /// Moving on to the next book sends nothing: a listener in the Library
    /// stays there, and one on the reader's screen is already there.
    let showReaderRequests = PassthroughSubject<UUID, Never>()

    // MARK: - What It Works With

    /// The library the books come from.
    private let library: LibraryViewModel
    /// The settings every reader follows.
    private let settings: SettingsViewModel
    /// Plays each reader's sounds.
    private let soundEffects: SoundEffectService
    /// Where readers post and listen.
    private let notificationCenter: NotificationCenter
    /// Where a finished book asks the next one to start playing.
    private let autoplayRequests: ReaderAutoplayRequests
    /// The preferences that keep the open book's ID.
    private let preferences: UserDefaults

    // MARK: - Following the Reader

    /// Reads the open reader after each of its changes, and tells only of a
    /// value that differs.
    private var readerFollower: ReaderSnapshot<PhoneReaderSnapshot>?
    /// What `readerFollower` tells, heard while the reader is open.
    private var followerSubscription: AnyCancellable?
    /// The app-wide requests to open a book, heard for as long as the session
    /// lasts.
    private var booksAskedForSubscription: AnyCancellable?
    /// Whether a press of Play waits for the open book to finish loading: a
    /// reader ignores Play while it loads, and the listener should not have
    /// to find Play twice.
    private var playsOnceLoaded = false

    /// A session over the app's stores, or a test's.
    ///
    /// - Parameters:
    ///   - notificationCenter: Where readers post and listen: the app's, or a
    ///     test's, so that the running app's windows never hear it.
    ///   - autoplayRequests: Where a finished book's request for the next one
    ///     waits. Nil uses the shared store, read here rather than as a default
    ///     argument, so that it is read inside this main-actor initializer, as
    ///     `ReaderViewModel` does.
    ///   - preferences: Keeps the open book's ID.
    init(
        library: LibraryViewModel,
        settings: SettingsViewModel,
        soundEffects: SoundEffectService,
        notificationCenter: NotificationCenter = .default,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        preferences: UserDefaults = TextMouthRuntime.current.preferences
    ) {
        self.library = library
        self.settings = settings
        self.soundEffects = soundEffects
        self.notificationCenter = notificationCenter
        self.autoplayRequests = autoplayRequests ?? .shared
        self.preferences = preferences

        // An import that opens its book, or a feed's episode, opens it here.
        // The library holds this closure and the session holds the library,
        // so it captures the session weakly.
        library.readerOpener = { [weak self] bookID in
            guard let self, self.openBook(withID: bookID) else { return }
            self.showReaderRequests.send(bookID)
        }
        booksAskedForSubscription = Self.booksAskedFor(on: notificationCenter)
            .sink { [weak self] bookID in
                // Delivered on the main queue, as `booksAskedFor(on:)` asks.
                MainActor.assumeIsolated {
                    _ = self?.openBook(withID: bookID)
                }
            }
    }

    /// The books the app asks to have opened on `center`: the one after a book
    /// that finished, and the one Next in Folder opens without playing. On the
    /// Mac only the window router hears these, through the app delegate; here
    /// the session is the app's one "window", and without this, Continue to
    /// Next Book says "Starting: Dune" and nothing starts.
    ///
    /// Nonisolated, so that the closure reading each notification belongs to no
    /// actor: a notification reaches its observers on the thread that posted
    /// it, and a main-actor closure stops the app if run on another thread.
    /// Delivered on the main queue, a later turn than the post: the reader
    /// posting is partway through its own work, and closing it here would pull
    /// it out from under that work.
    private nonisolated static func booksAskedFor(on center: NotificationCenter) -> AnyPublisher<UUID, Never> {
        let names: [Notification.Name] = [.continueToNextBook, .openBookWindow]
        return Publishers.MergeMany(names.map { center.publisher(for: $0) })
            .compactMap { GlobalAction(notification: $0)?.bookToOpen }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Opening and Closing

    /// Opens `book`: its reader, when it is the book open now, and otherwise
    /// a new reader, the old one saved and closed first. It leaves the new
    /// book at its place, not playing, unless a finished book asked for it,
    /// when the reader claims that request itself as its book loads, as a
    /// reader does on the Mac.
    ///
    /// The old reader closes before the new one is made, so that two books are
    /// never in memory at once on a phone, and so that the new reader finds no
    /// other in the media session. A sleep timer held for the new book outlives
    /// the old reader (`ReaderViewModel.close()`), and the new one takes it.
    ///
    /// - Parameter book: The book to open. The library's own row for it is what
    ///   the reader starts from, so a row a view read a while ago never opens
    ///   the book at an old place.
    /// - Returns: The reader of the book.
    @discardableResult
    func open(_ book: Book) -> ReaderViewModel {
        if let reader, reader.book.id == book.id, !reader.hasClosed {
            return reader
        }
        closeReader()
        let current = library.bookByID(book.id) ?? book
        let opened = BookReaderWindowView.makeReader(
            book: current,
            libraryViewModel: library,
            settingsViewModel: settings,
            // No switcher: a reader with none goes on to the next book by the
            // notifications heard above, whatever the window setting says.
            showBook: nil,
            requestedBookID: current.id,
            autoplayRequests: autoplayRequests,
            notificationCenter: notificationCenter
        )
        // At once, not as a view appears: a Play from the AirPods or a request
        // to play the book may come first, and it plays a sound.
        opened.soundEffectService = soundEffects
        library.markBookOpened(current.id)
        preferences.set(current.id.uuidString, forKey: Self.openBookPreferenceKey)
        reader = opened
        follow(opened)
        return opened
    }

    /// Saves and closes the open book, if any. A closed reader is finished and
    /// never plays again, which is why nothing calls this from a view's
    /// disappearing. The book is no longer one to open at the next launch.
    func closeReader() {
        guard let closing = reader else { return }
        // Stop hearing it first: what it publishes as it closes is no news.
        readerFollower = nil
        followerSubscription = nil
        playsOnceLoaded = false
        reader = nil
        snapshot = nil
        closing.close()
        preferences.removeObject(forKey: Self.openBookPreferenceKey)
    }

    /// Opens the book `bookID` as an app-wide request asks.
    ///
    /// A book that has left the library since it was asked for opens nothing,
    /// and nothing is left waiting for it: not its request to play, nor a sleep
    /// timer, which would count toward pausing nothing.
    ///
    /// - Returns: Whether the book is open now.
    private func openBook(withID bookID: UUID) -> Bool {
        guard let book = library.bookByID(bookID) else {
            DiagnosticLog.event(
                .app,
                "phone session: asked to open a book no longer in the library: \(bookID.uuidString.prefix(8))"
            )
            autoplayRequests.discard(for: bookID)
            SleepTimerService.shared.releaseHeld(forBook: bookID)
            return false
        }
        open(book)
        return true
    }

    /// The book that was open when the app last ended, for opening again at
    /// launch, paused at its place; nil when none was, or it has left the
    /// library.
    var bookToReopenAtLaunch: Book? {
        guard let saved = preferences.string(forKey: Self.openBookPreferenceKey),
              let bookID = UUID(uuidString: saved) else { return nil }
        return library.bookByID(bookID)
    }

    // MARK: - Play and Pause

    /// Plays or pauses the open book, as its Play button does. A press while it
    /// loads waits for the load to end, and a second one takes it back.
    func togglePlayPause() {
        guard let reader else { return }
        guard reader.isLoading else {
            reader.togglePlayPause()
            return
        }
        let bookID = reader.book.id
        if autoplayRequests.hasRequest(for: bookID) {
            // A finished book asked for this one, so it is about to play: the
            // press means stop, as Play/Pause does on a book about to play.
            autoplayRequests.discard(for: bookID)
            playsOnceLoaded = false
        } else {
            playsOnceLoaded.toggle()
        }
    }

    /// What the magic tap does, and the fallback of the remote commands: plays
    /// or pauses the open book from any screen; with none open, opens the book
    /// last opened without changing the screen, and plays it once it has
    /// loaded, as a press of Play would, so a finished book says what Play says
    /// of it.
    ///
    /// - Returns: False when no book has ever been opened, or the last one has
    ///   left the library, so that the system's own fallback runs.
    func togglePlayPauseFromAnywhere() -> Bool {
        if reader != nil {
            togglePlayPause()
            return true
        }
        guard let book = library.lastOpenedBook else { return false }
        let opened = open(book)
        if opened.isLoading {
            playsOnceLoaded = true
        } else {
            opened.playUnlessUnderWay()
        }
        return true
    }

    // MARK: - Following

    /// Follows `reader` for as long as it is open. A follower of its own reads
    /// the reader a turn of the main queue after each change, and tells only of
    /// a value that differs. So `snapshot` never hears the reader's place move.
    private func follow(_ reader: ReaderViewModel) {
        let follower = ReaderSnapshot(of: reader) { PhoneReaderSnapshot(of: $0) }
        readerFollower = follower
        followerSubscription = follower.$value.sink { [weak self] latest in
            self?.readerChanged(to: latest)
        }
    }

    /// Publishes `latest`, and plays a book whose load has ended if a press of
    /// Play waits for that. Since a follower reads a turn after the change,
    /// everything the reader does as its load ends has been done by now, the
    /// claim of a finished book's request among them, so a book that has
    /// started is left as it is: hence `playUnlessUnderWay()`, which never
    /// pauses, and not Play/Pause, which would. A book that could not load has
    /// nothing to play, and `play()` refuses it.
    private func readerChanged(to latest: PhoneReaderSnapshot) {
        snapshot = latest
        guard playsOnceLoaded, !latest.isLoading else { return }
        playsOnceLoaded = false
        reader?.playUnlessUnderWay()
    }
}
