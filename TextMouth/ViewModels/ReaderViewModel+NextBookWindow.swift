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

    /// What this reader's window is doing now, read from AppKit: on screen,
    /// minimized, or hidden with the app; a sheet or alert over it; a text
    /// field being typed in (the field editor is the window's first
    /// responder). A reader with no window, as one whose window has gone,
    /// stands as `NextBookWindowStanding.noWindow`.
    var windowStanding: NextBookWindowStanding {
        if let windowStandingOverride { return windowStandingOverride }
        guard let window = hostWindow else { return .noWindow }
        return NextBookWindowStanding(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            appIsHidden: NSApp.isHidden,
            hasSheet: window.attachedSheet != nil,
            fieldIsBeingEdited: (window.firstResponder as? NSTextView)?.isFieldEditor == true
        )
    }

    /// Whether switching the window to another book could lose something,
    /// so that the book opens in a new window as before instead:
    /// - this reader has closed, or its window is gone or off screen: the
    ///   listener pressed Command-W between "Starting: <title>" and the
    ///   request, and the hand-over goes on as announced, in a new window;
    /// - a sheet or an alert is open over the window (Edit Book Information,
    ///   Search in Book, the headings, the bookmarks, the sleep timer, the
    ///   voice, Export, an error), or a field is being typed in (Go to
    ///   Percent, Time, or Page): the switch would take them away, and the
    ///   typing would reach the next book's single-key shortcuts;
    /// - this book's text is being edited in another app (Edit Text), whose
    ///   changes arrive through this reader;
    /// - the library is moving or unavailable, when the app refuses to open a
    ///   book, which a switch would go around.
    ///
    /// A running sleep timer of this reader's is not one: it goes on with the
    /// next book, in this window or another (`handOverSleepTimer(to:)`).
    var switchingTheWindowCouldLoseWork: Bool {
        hasClosed
            || windowStanding.isBusy
            || libraryViewModel.textEditSessions.isEditing(book.id)
            || libraryViewModel.dataDirectoryMove != nil
            || libraryViewModel.dataDirectoryUnavailability != nil
    }

    /// Takes `window` as this reader's window, as the reader's view finds
    /// it, and, when a switch made this reader, sees to the window's focus
    /// once the book has loaded (`placeFocusAfterSwitch`): a window opened
    /// for a book announces itself and places its own first focus, but a
    /// window switched to another book is the same window, and nothing
    /// announces it. The check waits for the load because the book's own
    /// focus trigger runs only then (`SwitchedWindowFocus`). The request is
    /// claimed once, so a window found again changes nothing, and a reader
    /// opened for a new window finds none.
    func attach(to window: NSWindow) {
        hostWindow = window
        guard !hasClosed, windowSwitchRequests.consume(for: book.id) != nil else { return }
        DiagnosticLog.trace(.playback, "next book: this window was switched to this book; its focus is seen to once it has loaded")
        if isLoading {
            windowAwaitingFocusAfterLoad = window
        } else {
            placeFocusAfterSwitch(window)
        }
    }

    /// Sees to the focus of the window a switch made this reader's, found
    /// before the book had loaded: called as the load ends.
    func placeFocusAfterSwitchIfDue() {
        guard !hasClosed, let window = windowAwaitingFocusAfterLoad else { return }
        windowAwaitingFocusAfterLoad = nil
        placeFocusAfterSwitch(window)
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
        // A sleep timer that ran out since the move was announced, or began to
        // fade out while it was to go on with the next book, has ended
        // listening: the next book is not started, and what the timer said as
        // it ran out is all that is said. The requests made for the book, and
        // the timer's note that it ran out for this book, are dropped.
        let timerRanOut = moveAnnouncedAt.map { sleepTimerService.didExpire(whileOwnedBy: readerID, since: $0) } ?? false
        if timerRanOut || (moveCarriesSleepTimer && sleepTimerIsFadingOutHere) {
            moveCarriesSleepTimer = false
            moveAnnouncedAt = nil
            DiagnosticLog.trace(.playback, "next book: the sleep timer ended listening before the book was asked for; not starting it")
            autoplayRequests.discard(for: nextBookID)
            readingListRequests.discard(for: nextBookID)
            sleepTimerService.dropHold(forBook: nextBookID)
            _ = sleepTimerService.consumeExpiredWhileHeld(forBook: nextBookID)
            return
        }
        moveCarriesSleepTimer = false
        moveAnnouncedAt = nil
        // A running timer goes on with the book, wherever it shows: held for it
        // since the move was announced, and held again here for a caller that
        // announced nothing.
        holdSleepTimer(forBook: nextBookID)
        // Asked for now, with the other requests, before the notification or
        // the switch: a reader open for the book takes the timer before it
        // plays, and one the ask opens takes it as its load ends.
        sleepTimerService.markAsked(forBook: nextBookID)
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
            // closing must leave the window registered for the new one. The
            // request for the new reader to see to the window's focus comes
            // with the others, before the switch.
            hasSwitchedWindow = true
            windowSwitchRequests.request(for: nextBookID)
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
