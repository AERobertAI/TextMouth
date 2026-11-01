import AppKit
import Foundation

// MARK: - Where the Next Book Opens (0.2.5)

/// The last step of every move from one book to another: the end of a book
/// going on, the reading list's Next and Previous, and the folder's Next and
/// Previous. By the user's setting the next book shows in this reader's own
/// window in place of this book, or opens in a new window as before 0.2.5.
///
/// Every request for the next book (to play it, to read it from the reading
/// list) is made first, as before, so the reader that takes over claims it
/// once it has loaded, whichever way it was reached.
extension ReaderViewModel {

    /// The window choice for a move through this book's feed or folder:
    /// the feed's or folder's own, when it has made one and its items go on
    /// (`NextBookWindowRule.choice`), else the global setting.
    var folderMoveWindowChoice: NextBookWindow {
        NextBookWindowRule.choice(
            options: libraryViewModel.listeningOptions(of: book),
            global: settingsViewModel.nextBookWindow,
            globalEndOfBook: settingsViewModel.endOfBookBehavior
        )
    }

    /// The window choice for a move through the reading list, which has no
    /// choice of its own and follows the global setting.
    var readingListMoveWindowChoice: NextBookWindow {
        settingsViewModel.nextBookWindow
    }

    /// Whether this reader's window is on screen, or minimized, so that a
    /// book shown in it would be seen. A reader whose window has closed, or
    /// that has no window, is not.
    private var hostWindowIsOnScreen: Bool {
        if let hostWindowIsOnScreenOverride { return hostWindowIsOnScreenOverride }
        guard let window = hostWindow else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// Whether switching this window to another book could lose something,
    /// so that the book opens in a new window as before instead:
    /// - this reader has closed, or its window is gone or off screen: the
    ///   listener pressed Command-W between "Starting: <title>" and the
    ///   request, and the hand-over goes on as announced, in a new window;
    /// - a sheet or an alert is open over the window (Edit Book Information,
    ///   Search in Book, the headings, the bookmarks, the sleep timer, the
    ///   voice, Export, an error);
    /// - this book's text is being edited in another app (Edit Text), whose
    ///   changes arrive through this reader;
    /// - the library is moving, when the app refuses to open a book.
    var switchingTheWindowCouldLoseWork: Bool {
        hasClosed
            || !hostWindowIsOnScreen
            || hostWindow?.attachedSheet != nil
            || libraryViewModel.textEditSessions.isEditing(book.id)
            || libraryViewModel.dataDirectoryMove != nil
    }

    /// Shows the book `nextBookID`, which every request for it has been
    /// made for, as `choice` and the state of this window say
    /// (`NextBookWindowRule.action`).
    ///
    /// - Parameters:
    ///   - nextBookID: The book listening goes on with.
    ///   - choice: The window choice in force for this move.
    ///   - openANewWindow: Opens the book's window, or brings it forward
    ///     when it is open already, as before 0.2.5: it posts the
    ///     notification the app turns into an open.
    func showNextBook(
        _ nextBookID: UUID,
        under choice: NextBookWindow,
        openingANewWindowWith openANewWindow: () -> Void
    ) {
        let action = NextBookWindowRule.action(
            choice: choice,
            isBusy: switchingTheWindowCouldLoseWork,
            canSwitch: nextBookWindowSwitcher != nil,
            nextBookIsOpenElsewhere: libraryViewModel.openBookIDs.contains(nextBookID)
        )
        DiagnosticLog.trace(.playback, "next book: window choice \(choice.rawValue); \(action)")
        switch action {
        case .openANewWindow:
            openANewWindow()
        case .switchThisWindow:
            // Marked first: the switch rebuilds the window's view, whose
            // closing must leave the window registered for the new one.
            hasSwitchedWindow = true
            nextBookWindowSwitcher?(nextBookID)
        case .bringTheOpenWindowForwardThenClose:
            // The other window comes forward as before; this one goes on
            // the next turn of the main queue, once that request is
            // routed, so no two windows show one book.
            openANewWindow()
            DispatchQueue.main.async { [weak self] in
                self?.hostWindow?.close()
            }
        }
    }
}
