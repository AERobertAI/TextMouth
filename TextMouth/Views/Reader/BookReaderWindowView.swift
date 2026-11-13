import SwiftUI

/// Holds a reader window's sleep timer for the window's content, without
/// observing it: it publishes nothing. A `@StateObject` timer would subscribe
/// `ReaderWindowContent` to every change of the timer, and so run its body, and
/// `BookReaderWindowView.init` below it (a linear look-up of the book among
/// the library's), once a second in every window with a counting timer. The
/// sleep timer's sheet observes the timer itself, and the reader's status
/// shows it as the reader publishes, as it did before each window had one.
@MainActor
final class WindowSleepTimerHolder: ObservableObject {
    /// The window's sleep timer.
    let timer = SleepTimerService()
}

/// A reader window's content, above the book it shows (November 13, 2026):
/// the window's own sleep timer lives here, made once for the window, and
/// each book the window shows is a `BookReaderWindowView` below it, with an
/// identity of its own (`.id`). So when listening goes on to another book in
/// this window (0.2.5), SwiftUI makes a new view and reader for the book, and
/// the window keeps its timer, which the new reader takes over
/// (`ReaderViewModel.claimSleepTimerHandOver()`). The user, November 13: "I
/// want each sleep timer to be refactored to be per book view window not
/// global".
struct ReaderWindowContent: View {
    /// The book the window shows, which the scene keeps: a switch to the
    /// next book in place sets it.
    @Binding var bookID: UUID?
    let libraryViewModel: LibraryViewModel
    let settingsViewModel: SettingsViewModel
    /// The window's sleep timer, made once for the window and kept for as
    /// long as SwiftUI keeps the window, in a holder that publishes nothing
    /// (`WindowSleepTimerHolder`), so a tick of the timer does not run this
    /// body.
    @StateObject private var sleepTimerHolder = WindowSleepTimerHolder()

    var body: some View {
        let _ = ViewBodyCounter.record("ReaderWindowContent")
        if let shownBookID = bookID {
            BookReaderWindowView(
                bookID: shownBookID,
                libraryViewModel: libraryViewModel,
                settingsViewModel: settingsViewModel,
                sleepTimer: sleepTimerHolder.timer,
                // Listening goes on to another book in this window (0.2.5):
                // the window's book changes, and `.id` below makes a new view,
                // with a new reader, of it.
                showBook: { nextBookID in $bookID.wrappedValue = nextBookID }
            )
            // Without an identity of its own for each book, SwiftUI would
            // keep the old view and its reader, and the window would go on
            // showing the old book.
            .id(shownBookID)
        }
    }
}

/// Root view for a book reader window. Creates and manages a ReaderViewModel for the book.
struct BookReaderWindowView: View {
    /// The identifier of the reader window scene. Each of its windows
    /// shows one book and is opened with that book's ID.
    nonisolated static let windowID = "book-reader"

    let bookID: UUID
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var soundEffectService: SoundEffectService
    @StateObject private var viewModel: ReaderViewModel
    /// Opens reader windows. Lent to the router, which has no openWindow of
    /// its own, to open a book's reader while no Library window is open.
    @Environment(\.openWindow) private var openWindow

    /// A view of the book `bookID` in a reader window.
    ///
    /// - Parameters:
    ///   - sleepTimer: The window's sleep timer, which the window's content
    ///     keeps above each book it shows (`ReaderWindowContent`); nil, for a
    ///     view with no window content around it, gives the reader the
    ///     default (`ReaderViewModel.init(sleepTimer:)`).
    ///   - showBook: Sets the window's book (`makeReader`).
    init(
        bookID: UUID,
        libraryViewModel: LibraryViewModel,
        settingsViewModel: SettingsViewModel,
        sleepTimer: SleepTimerService? = nil,
        showBook: ((UUID) -> Void)? = nil
    ) {
        self.bookID = bookID
        // Create the ReaderViewModel as a StateObject
        let book = libraryViewModel.bookByID(bookID) ?? Book(
            title: "Unknown",
            format: .txt,
            filePath: "",
            md5Hash: ""
        )
        _viewModel = StateObject(wrappedValue: Self.makeReader(
            book: book,
            libraryViewModel: libraryViewModel,
            settingsViewModel: settingsViewModel,
            showBook: showBook,
            requestedBookID: bookID,
            sleepTimer: sleepTimer
        ))
    }

    /// The reader of `book`, given its window's sleep timer and the means to
    /// show another book in this window when listening goes on to it
    /// (0.2.5): `showBook` changes the book the window's scene presents,
    /// which makes a new view, and a new reader, in the same window
    /// (`ReaderWindowContent`), which keeps the window's timer.
    ///
    /// - Parameters:
    ///   - requestedBookID: The book the window was asked for, which the reader
    ///     of a placeholder for a missing book does not carry.
    ///   - autoplayRequests: The stores and center the reader uses: the app's,
    ///     unless a test gives it its own.
    ///   - showBook: Sets the window's book; nil, for a view with no
    ///   scene to set it in, leaves the reader unable to switch, and it then
    ///   opens a new window as before.
    ///   - sleepTimer: The sleep timer of the reader's window; nil gives the
    ///     reader the default (`ReaderViewModel.init(sleepTimer:)`).
    static func makeReader(
        book: Book,
        libraryViewModel: LibraryViewModel,
        settingsViewModel: SettingsViewModel,
        showBook: ((UUID) -> Void)?,
        requestedBookID: UUID,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        readingListRequests: ReadingListOpenRequests? = nil,
        windowSwitchRequests: WindowSwitchRequests? = nil,
        notificationCenter: NotificationCenter = .default,
        sleepTimer: SleepTimerService? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: libraryViewModel,
            settingsViewModel: settingsViewModel,
            autoplayRequests: autoplayRequests,
            readingListRequests: readingListRequests,
            windowSwitchRequests: windowSwitchRequests,
            notificationCenter: notificationCenter,
            sleepTimer: sleepTimer
        )
        reader.nextBookWindowSwitcher = showBook
        // A book deleted since the window was asked for is a placeholder with
        // an ID of its own: a sleep timer held for the book asked for would
        // never be taken, so it is released here, and said once the error view
        // has read that the book is gone.
        if libraryViewModel.bookByID(requestedBookID) == nil {
            reader.releaseSleepTimerHeld(forBook: requestedBookID, afterTheReason: true)
        }
        return reader
    }

    var body: some View {
        // Read while the view is installed, as SwiftUI requires, and kept
        // by the router for opening a book's reader from here.
        let openReaderWindow = openWindow
        ReaderView(viewModel: viewModel)
            .background(WindowAccessor(
                onWindowFound: { window in
                    viewModel.attach(to: window)
                    // With no Library window open, the router opens a book's
                    // reader through a reader window like this one (TODO A05).
                    LibraryWindowRouter.shared.registerReaderWindow(window) { bookID in
                        openReaderWindow(id: Self.windowID, value: bookID)
                    }
                    NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
                },
                onWindowBecameKey: {
                    // Focuses the reader's media session, and has the menus
                    // ask afresh whether it can release the media controls.
                    viewModel.windowBecameKey()
                }
            ))
            .focusedValue(\.activeWindowType, .reader)
            .focusedValue(\.canReleaseMediaControls, viewModel.canReleaseMediaControls)
            // Next in Reading List and Previous in Reading List are
            // available while this reader reads its book from the list
            // (FR09), whether or not a view of it holds keyboard focus.
            .focusedSceneValue(\.readsFromReadingList, viewModel.isOpenedFromReadingList)
            // Go to Page… is available while this reader's book has more
            // than one page (PG02), as above.
            .focusedSceneValue(\.readerHasPages, viewModel.hasSeveralPages)
            // Next in Folder and Previous in Folder are offered in a reader
            // window (0.2.5), whether or not a view of it holds keyboard
            // focus.
            .focusedSceneValue(\.isReaderWindow, true)
            .navigationTitle(windowTitle)
            .onAppear {
                libraryViewModel.markBookOpened(bookID)
                NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
            }
            .onDisappear {
                // A reader whose window now shows another book leaves the
                // window registered: the new view registered the same
                // window, perhaps before this view disappeared, and an
                // unregister here would take its entry away (0.2.5).
                if !viewModel.hasSwitchedWindow, let window = viewModel.hostWindow {
                    LibraryWindowRouter.shared.unregisterReaderWindow(window)
                }
                viewModel.close()
            }
            .frame(minWidth: 600, minHeight: 400)
    }

    /// The window's title, which follows the reader: it changes as the book
    /// is renamed, and as it starts or stops being read from the reading
    /// list (FR09).
    private var windowTitle: String {
        Self.windowTitle(for: viewModel.book, readFromReadingList: viewModel.isOpenedFromReadingList)
    }

    /// What a reader window's title begins with for a book read from
    /// anywhere but the reading list.
    nonisolated static let windowTitlePrefix = "Book"

    /// The title of the reader window of `book`: "Book: <title> by
    /// <author>", or "Book: <title>" when the author is unknown. A book read
    /// from the reading list (FR09) begins "Reading List" in place of
    /// "Book", so the window says it wherever VoiceOver or an eye meets it,
    /// as the user asked on October 7, 2026: "the window title should be
    /// slightly different to indicate it in some way".
    nonisolated static func windowTitle(for book: Book, readFromReadingList: Bool) -> String {
        let prefix = readFromReadingList ? ReadingListReaderWording.windowTitlePrefix : windowTitlePrefix
        if Book.isUnknownAuthor(book.author) {
            return "\(prefix): \(book.title)"
        }
        return "\(prefix): \(book.title) by \(book.author)"
    }
}
