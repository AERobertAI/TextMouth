import Foundation

// MARK: - A Window Switched to a Book

/// A request that a book's reader place keyboard and VoiceOver focus in its
/// window, because the window did not open for it: another reader switched
/// its window to this book (0.2.5, `ReaderViewModel.showNextBook`).
///
/// A window opened for a book gets its first focus from the views it makes
/// (the play button's `StandardVoiceOverFocus`, `InitialVoiceOverFocusModifier`
/// on the loading and error states), and the system announces the new window.
/// A window switched to another book is the same window, and nothing
/// announces it, so the reader made for the switch claims this request once
/// its window is found and sees to the focus (`SwitchedWindowFocus`). A
/// reader opened for a new window finds no request, and does nothing more
/// than before.
///
/// A reader window is identified by its book's ID alone, so the wish cannot
/// ride on the window's value; it waits in `WindowSwitchRequests`, a
/// `ReaderRequestStore`, as the autoplay and reading-list requests do.
struct WindowSwitchRequest: ReaderRequest {
    /// The book whose reader claims the request: the one the window now shows.
    let bookID: UUID
    /// When the request was made.
    let createdAt: Date
}

/// The requests a switched window leaves for the readers it makes: a store
/// of the one shape every reader request takes (`ReaderRequestStore`).
typealias WindowSwitchRequests = ReaderRequestStore<WindowSwitchRequest>

/// The store readers use unless a test gives a reader its own, made on the
/// main actor at its first use.
@MainActor private let sharedWindowSwitchRequests = WindowSwitchRequests()

extension ReaderRequestStore where Request == WindowSwitchRequest {
    /// The store readers use unless a test gives a reader its own.
    static var shared: WindowSwitchRequests {
        sharedWindowSwitchRequests
    }

    /// Ask that the reader of `bookID` place focus in its window once it has
    /// found it, replacing any request already waiting for that book.
    ///
    /// - Returns: The request made.
    @discardableResult
    func request(for bookID: UUID) -> WindowSwitchRequest {
        add(WindowSwitchRequest(bookID: bookID, createdAt: currentDate))
    }
}
