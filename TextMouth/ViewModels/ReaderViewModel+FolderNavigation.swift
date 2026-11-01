import Foundation

// MARK: - Next and Previous in Folder (0.2.5)

extension ReaderViewModel {

    /// Next in Folder (going down) and Previous in Folder (going up): goes
    /// to the item below or above this book in its folder, or in its feed,
    /// and plays it when this book was playing, as Next in Reading List does
    /// for the list. The user asked on November 1, 2026 for "go to
    /// next/previous episodes in feeds or normal folders".
    ///
    /// The item is the one the end of a book would go on to in that
    /// direction (`LibraryViewModel.succession(after:going:skippingFinished:)`,
    /// the one copy of the search): in the folder's order, passing over
    /// finished items when the feed's or folder's options say so (the
    /// standard options do). A feed's episode whose file is not here is
    /// downloaded first, and goes on once it arrives, as at a book's end
    /// (`waitForNextEpisode`).
    ///
    /// A playing book pauses where it is, without the pause sound, since the
    /// book that starts makes its own; a Where Am I announcement speaking
    /// ends with that pause, without resuming its book. The item is announced,
    /// then asked for after the moment Continue to Next Book gives VoiceOver
    /// to begin: "Starting: <title>" for one that plays
    /// (`continueToNextBook(_:under:)`), "Opening: <title>" for one that does
    /// not (`openInFolder(_:)`). This reader's sleep timer in effect keeps the
    /// item from starting, since it could never pause it, and the
    /// announcement says so. With no item that way it says so, and why when
    /// only finished items lie there, and changes nothing.
    ///
    /// Where the item shows, in this window or a new one, follows the feed's
    /// or folder's own choice, else the global one (`folderMoveWindowChoice`),
    /// read as the item is asked for.
    ///
    /// - Parameter direction: The command: down is Next in Folder, up is
    ///   Previous in Folder. The way the item is looked for is the way the
    ///   end of this book would go on (`EndOfBookRule.direction`: up for a
    ///   feed or folder that plays the one above, down for any other, Stop
    ///   included), for Next, and the other way for Previous. What is spoken
    ///   follows the command ("next", "previous"), and what lies that way
    ///   follows the way looked, as the end of a book says it.
    func goThroughFolder(_ direction: ReadingList.Direction) {
        let rule = endOfBookRule
        let looking = direction == .down ? rule.direction : rule.direction.opposite
        let succession = libraryViewModel.succession(
            after: book, going: looking, skippingFinished: rule.skipsFinished
        )
        // Nothing that way: say why, and leave this book as it is, playing
        // or not.
        if case .nothing(let note) = succession {
            DiagnosticLog.trace(.playback, "folder: nothing \(looking == .down ? "below" : "above") this book (\(note))")
            announceToVoiceOver(FolderNavigationWording.nothingThatWay(note))
            return
        }
        // This decision supersedes a wait for an episode that an earlier
        // one began.
        nextEpisodeWait = nil
        // The pause, the sleep timer's rule, the announcement, and the
        // moment before the item is asked for are the reading list's too
        // (`beginMoveToAnotherBook()`, `announceMove(to:titled:start:through:)`).
        let start = beginMoveToAnotherBook()
        switch succession {
        case .nothing:
            // Said above.
            return

        case .book(let neighbor):
            DiagnosticLog.trace(.playback, "folder: going \(direction == .down ? "down" : "up") to a book; plays: \(start.plays)")
            announceMove(to: neighbor.id, titled: neighbor.title, start: start, through: .folder)

        case .episodeToDownload(let feedID, let item):
            announceToVoiceOver(FolderNavigationWording.downloading(item, going: direction))
            DiagnosticLog.trace(.playback, "folder: the episode \(direction == .down ? "below" : "above") is not here; downloading it")
            let cause = NextEpisodeCause.folderMove(direction: direction, wasPlaying: start.wasPlaying)
            let plays = start.plays
            waitForNextEpisode(item, of: feedID, cause: cause) { bookID in
                self.askForBook(bookID, plays: plays, through: .folder)
            }
        }
    }

    /// Opens the book `bookID` without starting it: its window, or this
    /// one as the setting says (`showNextBook`), exactly as Next in Reading
    /// List opens a book that does not play (`openFromReadingList(_:)`), but
    /// with no request to read it from the list.
    func openInFolder(_ bookID: UUID) {
        showNextBook(bookID, under: folderMoveWindowChoice) {
            notificationCenter.post(name: .openBookWindow, object: bookID)
        }
    }
}
