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
    func goThroughFolder(_ direction: ReadingList.Direction) {
        let succession = libraryViewModel.succession(
            after: book, going: direction, skippingFinished: endOfBookRule.skipsFinished
        )
        // Nothing that way: say why, and leave this book as it is, playing
        // or not.
        if case .nothing(let note) = succession {
            DiagnosticLog.trace(.playback, "folder: nothing \(direction == .down ? "below" : "above") this book (\(note))")
            announceToVoiceOver(FolderNavigationWording.nothingThatWay(note))
            return
        }
        // This decision supersedes a wait for an episode that an earlier
        // one began.
        nextEpisodeWait = nil
        // Playing: speech or audio under way, or paused only while a Where
        // Am I announcement speaks, or until the end sound of one that ended
        // has played (`whereAmIWillPlayBook`).
        let wasPlaying = isPlaybackUnderWay || whereAmIWillPlayBook
        let sleepTimerKeepsItFromStarting = wasPlaying && sleepTimerEndsListeningHere
        // The pause ends a Where Am I announcement too, without resuming
        // this book, even for a book that was not playing, whose
        // announcement would otherwise speak over the item's.
        if wasPlaying || isWhereAmIUnderWay {
            pause(playingPauseSound: false)
        }
        let plays = wasPlaying && !sleepTimerKeepsItFromStarting
        switch succession {
        case .nothing:
            // Said above.
            return

        case .book(let neighbor):
            announceToVoiceOver(
                plays
                    ? EndOfBookWording.starting(neighbor.title)
                    : ReadingListReaderWording.opening(neighbor.title, sleepTimerKeptItFromStarting: sleepTimerKeepsItFromStarting)
            )
            DiagnosticLog.trace(.playback, "folder: going \(direction == .down ? "down" : "up") to a book; plays: \(plays)")
            // Asked for once VoiceOver has begun the announcement, as
            // Continue to Next Book asks for its book.
            let neighborID = neighbor.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
                self.askForFolderItem(neighborID, plays: plays)
            }

        case .episodeToDownload(let feedID, let item):
            announceToVoiceOver(FolderNavigationWording.downloading(item, going: direction))
            DiagnosticLog.trace(.playback, "folder: the episode \(direction == .down ? "below" : "above") is not here; downloading it")
            waitForNextEpisode(item, of: feedID, fromFinishedBook: false, plays: plays) { bookID in
                self.askForFolderItem(bookID, plays: plays)
            }
        }
    }

    /// Asks for the item `bookID`, which Next in Folder or Previous in
    /// Folder goes to, once it is announced (or downloaded): to be played,
    /// as a book that ends continues to the next one
    /// (`continueToNextBook(_:under:)`), or only opened.
    private func askForFolderItem(_ bookID: UUID, plays: Bool) {
        if plays {
            continueToNextBook(bookID, under: folderMoveWindowChoice)
        } else {
            openInFolder(bookID)
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
