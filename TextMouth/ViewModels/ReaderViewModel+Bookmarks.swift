import SwiftUI
import AppKit

// MARK: - Bookmarks, Search Results, Saved Position, and Metadata Editing

extension ReaderViewModel {

    // MARK: - Bookmarks

    /// Proximity threshold in characters for detecting nearby bookmarks.
    /// For audio books: half a second = 5 characters (10 chars/sec * 0.5).
    /// For text books: 10 characters.
    var bookmarkProximityThreshold: Int {
        isAudioBook ? 5 : 10
    }

    /// Find the closest bookmark within the proximity threshold of the given position.
    /// Only matches bookmarks in the same chapter. When multiple bookmarks fall
    /// within range, returns the one with the smallest distance.
    func nearbyBookmark(chapterIndex: Int, characterOffset: Int) -> Bookmark? {
        Self.nearbyBookmark(
            in: bookmarks,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            threshold: bookmarkProximityThreshold
        )
    }

    /// Pure proximity matcher shared by the reader and regression tests.
    /// Keeping the collection and threshold explicit makes audio/text behavior
    /// independently verifiable without constructing an entire reader window.
    nonisolated static func nearbyBookmark(
        in bookmarks: [Bookmark],
        chapterIndex: Int,
        characterOffset: Int,
        threshold: Int
    ) -> Bookmark? {
        bookmarks
            .filter { $0.chapterIndex == chapterIndex && abs($0.characterOffset - characterOffset) <= threshold }
            .min(by: { abs($0.characterOffset - characterOffset) < abs($1.characterOffset - characterOffset) })
    }

    /// Whether a bookmark exists near the current reading position
    var hasNearbyBookmark: Bool {
        nearbyBookmark(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset) != nil
    }

    /// Text of the heading containing `bookmark`: the location its row and
    /// rotor entry name. Nil before content loads, in a book without headings,
    /// or when the bookmark precedes the first heading; bookmarks never fall
    /// back to content-unit titles or numbers.
    func headingText(forBookmark bookmark: Bookmark) -> String? {
        HeadingPosition(
            in: headings,
            chapterIndex: bookmark.chapterIndex,
            characterOffset: bookmark.characterOffset
        ).headingText
    }

    /// Toggle a bookmark at the current position: if one exists nearby, remove it;
    /// otherwise add a new one. When adding, checks for overlap with existing
    /// bookmarks and adjusts position to avoid placing two bookmarks within
    /// each other's proximity zones. A bookmark added keeps the words around
    /// the offset it is saved at, the adjusted one (T06, `anchorToSave(at:)`).
    func toggleBookmarkAtCurrentPosition() {
        if let existing = nearbyBookmark(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset) {
            // Remove the nearby bookmark
            let number = existing.number
            removeBookmark(existing)
            announceToVoiceOver("Bookmark \(number) removed")
        } else {
            // Add a new bookmark, adjusting position if it would overlap with an existing one
            let chapterLength = content?.chapters.indices.contains(currentChapterIndex) == true
                ? content?.chapters[currentChapterIndex].text.utf16Length
                : nil
            let adjustedOffset = Self.adjustedBookmarkOffset(
                bookmarks: bookmarks,
                chapterIndex: currentChapterIndex,
                characterOffset: currentCharacterOffset,
                threshold: bookmarkProximityThreshold,
                chapterLength: chapterLength
            )
            libraryViewModel.addBookmark(
                bookID: book.id,
                chapterIndex: currentChapterIndex,
                characterOffset: adjustedOffset,
                label: "",
                anchor: anchorToSave(at: TextPlace(chapter: currentChapterIndex, offset: adjustedOffset))
            )
            bookmarks = libraryViewModel.bookmarksForBook(book.id)
            announceToVoiceOver("Bookmark \(bookmarks.count) added")
        }
    }

    /// Adjust a bookmark offset so it doesn't fall within the proximity zone
    /// of any existing bookmark in the same chapter. First tries nudging backward;
    /// if that still conflicts, scans forward through sorted bookmarks, jumping
    /// past each conflicting zone in turn. Guaranteed to terminate because the
    /// forward scan always advances.
    nonisolated static func adjustedBookmarkOffset(
        bookmarks: [Bookmark],
        chapterIndex: Int,
        characterOffset: Int,
        threshold: Int,
        chapterLength: Int?
    ) -> Int {
        let sameChapter = bookmarks
            .filter { $0.chapterIndex == chapterIndex }
            .sorted(by: { $0.characterOffset < $1.characterOffset })

        func clamped(_ offset: Int) -> Int {
            guard let chapterLength else { return max(0, offset) }
            return min(max(0, offset), max(0, chapterLength - 1))
        }

        // Quick check: no conflict at all
        guard sameChapter.contains(where: { abs($0.characterOffset - characterOffset) <= threshold }) else {
            return clamped(characterOffset)
        }

        // Try backward nudge first (only if position is before the first conflict)
        if let first = sameChapter.first(where: { abs($0.characterOffset - characterOffset) <= threshold }),
           characterOffset < first.characterOffset {
            let candidate = max(0, first.characterOffset - threshold - 1)
            if !sameChapter.contains(where: { abs($0.characterOffset - candidate) <= threshold }) {
                return clamped(candidate)
            }
        }

        // Forward scan: walk through sorted bookmarks, jumping past each conflict
        var adjusted = characterOffset
        for bm in sameChapter {
            if abs(bm.characterOffset - adjusted) <= threshold {
                adjusted = bm.characterOffset + threshold + 1
            }
        }
        return clamped(adjusted)
    }

    /// Add a bookmark at the current reading position with an optional label,
    /// keeping the words around it (T06, `anchorToSave(at:)`).
    ///
    /// - Returns: The bookmark added, so the bookmarks panel can move focus
    ///   to its row; nil when the library holds no record of this book and
    ///   so added nothing.
    @discardableResult
    func addBookmarkAtCurrentPosition(label: String = "") -> Bookmark? {
        // The bookmarks saved before this one. Whichever bookmark is new
        // afterwards is the one added here, wherever the library placed it.
        let existingIDs = Set(libraryViewModel.bookmarksForBook(book.id).map(\.id))
        libraryViewModel.addBookmark(
            bookID: book.id,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            label: label,
            anchor: anchorToSave(at: TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset))
        )
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        announceToVoiceOver("Bookmark \(bookmarks.count) added")
        return bookmarks.first { !existingIDs.contains($0.id) }
    }

    /// Update the user-facing label on an existing bookmark
    func updateBookmarkLabel(_ bookmark: Bookmark, label: String) {
        libraryViewModel.updateBookmarkLabel(bookID: book.id, bookmarkID: bookmark.id, label: label)
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
    }

    /// Navigate to the next bookmark after the current position
    func goToNextBookmark() {
        let sorted = bookmarks.sorted { $0.number < $1.number }
        if let next = sorted.first(where: {
            $0.chapterIndex > currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset > currentCharacterOffset)
        }) {
            navigatePreservingReturnPosition(
                chapterIndex: next.chapterIndex,
                characterOffset: next.characterOffset
            )
            announceToVoiceOver("Bookmark \(next.number)")
        }
    }

    /// Navigate to the previous bookmark before the current position
    func goToPreviousBookmark() {
        let sorted = bookmarks.sorted { $0.number > $1.number }
        if let prev = sorted.first(where: {
            $0.chapterIndex < currentChapterIndex ||
            ($0.chapterIndex == currentChapterIndex && $0.characterOffset < currentCharacterOffset)
        }) {
            navigatePreservingReturnPosition(
                chapterIndex: prev.chapterIndex,
                characterOffset: prev.characterOffset
            )
            announceToVoiceOver("Bookmark \(prev.number)")
        }
    }

    /// Delete a bookmark
    func removeBookmark(_ bookmark: Bookmark) {
        libraryViewModel.removeBookmark(bookID: book.id, bookmarkID: bookmark.id)
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
    }

    /// Navigate to a bookmark (from the bookmarks list), saving current position for return
    func navigateToBookmark(_ bookmark: Bookmark) {
        navigatePreservingReturnPosition(
            chapterIndex: bookmark.chapterIndex,
            characterOffset: bookmark.characterOffset
        )
        autoPlayIfEnabled()
    }

    /// Navigate to a search result, saving current position for return
    func navigateToSearchResult(chapterIndex: Int, characterOffset: Int) {
        navigatePreservingReturnPosition(
            chapterIndex: chapterIndex,
            characterOffset: characterOffset
        )
        autoPlayIfEnabled()
    }

    /// With Auto-play on navigate, plays the book after a jump from a panel
    /// as Play does, unless it plays or waits to play already
    /// (`playUnlessUnderWay()`). The play once went through Play/Pause,
    /// which paused a play waiting for its chapter, so a heading picked
    /// while an audiobook's chapter downloaded stopped the download, and the
    /// book stayed silent.
    func autoPlayIfEnabled() {
        guard settingsViewModel.autoPlayOnNavigate else { return }
        playUnlessUnderWay()
    }

    /// Save current position so the user can return to it after browsing headings/bookmarks
    func savePositionForReturn() {
        savedChapterIndex = currentChapterIndex
        savedCharacterOffset = currentCharacterOffset
        hasSavedPosition = true
    }

    /// Record the departure point and navigate through one shared path so every
    /// heading, bookmark, search, and explicit jump supports the Return button.
    /// Invalid unloaded-reader requests do not replace an existing return point.
    @discardableResult
    func navigatePreservingReturnPosition(chapterIndex: Int, characterOffset: Int) -> Bool {
        guard content?.chapters.isEmpty == false else { return false }
        savePositionForReturn()
        navigateTo(chapterIndex: chapterIndex, characterOffset: characterOffset)
        return true
    }

    /// Return to the position saved before the last heading/bookmark navigation
    func returnToSavedPosition() {
        guard hasSavedPosition else { return }
        hasSavedPosition = false
        navigateTo(chapterIndex: savedChapterIndex, characterOffset: savedCharacterOffset)
        announceToVoiceOver("Returned to previous position")
    }

    // MARK: - Metadata Editing

    /// Saves edited EPUB metadata through the library, which writes the
    /// library's copy of the EPUB file first when `writeToFile` asks (TODO
    /// A09), and returns what happened for the metadata editor: it closes
    /// after a success, and otherwise stays open with the user's edits beside
    /// the reason, so the user can save to the library only or try again.
    ///
    /// Only a save that succeeded changes this reader: its metadata, its
    /// book, and Now Playing, while the reader holds the media controls
    /// (`showSavedMetadataInNowPlaying()`), then show exactly what the
    /// library row and the book's record hold, content hash included.
    /// After a failure all of them
    /// stay as they were. Either way VoiceOver hears the outcome, which names
    /// the library's copy of the EPUB file whenever that file was, or could
    /// not be, written. A failure is not also set as `errorMessage`: the open
    /// editor shows it, and the reader's alert, waiting behind the editor,
    /// would report it again after the user had already acted on it.
    ///
    /// - Parameters:
    ///   - metadata: The edited metadata.
    ///   - opened: The metadata the editor opened with, which it kept while
    ///     this reader's own metadata took any change the library made
    ///     meanwhile, so the save changes only what the user changed.
    ///   - writeToFile: Whether to write the library's copy of the EPUB file.
    ///   - writer: Writes the file; tests pass one that fails.
    @discardableResult
    func saveEPUBMetadata(
        _ metadata: EPUBMetadata,
        openedAs opened: EPUBMetadata,
        writeToFile: Bool,
        writer: EPUBMetadataWriter = .system
    ) -> OperationOutcome {
        let save = libraryViewModel.saveEPUBMetadata(
            metadata,
            openedAs: opened,
            for: book,
            writingToFile: writeToFile,
            writer: writer
        )
        if let saved = save.savedBook {
            book.applyEditableMetadata(from: saved)
            // The row's fields, over the edit for the rest: a field the
            // library changed while the editor was open shows as the row
            // has it, not as the editor opened with it.
            epubMetadata = saved.mergingEditableEPUBMetadata(metadata)
            showSavedMetadataInNowPlaying()
        }
        announceToVoiceOver(save.message)
        return save.outcome
    }

    /// Saves edited audio metadata through the library: the title, the
    /// artist as the author, and the album, genre, and year, each only if
    /// the user changed it since the editor opened with `opened`, which is
    /// recorded as edited by hand on the row and in bookInfo.json inside the
    /// .tmb package. The reader's book, its metadata, and Now Playing, while
    /// the reader holds the media controls (`showSavedMetadataInNowPlaying()`),
    /// then show the row as saved. A book that has left the library is not
    /// saved, and the reader stays as it was and says so.
    func saveAudioMetadata(_ metadata: AudioMetadata, openedAs opened: AudioMetadata) {
        // The row as saved carries the record of hand edits.
        guard let saved = libraryViewModel.updateBookMetadata(
            Book.MetadataEdit(opened: opened, saved: metadata),
            of: book.id
        ) else {
            // The words the EPUB editor's save uses for such a book.
            announceToVoiceOver(EPUBMetadataSaveWording.notInLibrary(title: book.title))
            return
        }
        book.applyEditableMetadata(from: saved)
        // The row's fields, over the edit for the rest, as for an EPUB.
        audioMetadata = saved.mergingEditableAudioMetadata(metadata)
        announceToVoiceOver("Metadata updated")
        showSavedMetadataInNowPlaying()
    }

    /// Shows the book's title and author, as a metadata save left them, in
    /// the system's Now Playing, only while this reader holds the media
    /// controls (`NowPlayingSession.holdsMediaControls`): its book playing,
    /// paused, or resting finished there, shown as it is. A reader that
    /// holds nothing, because it never played, stopped, or released them,
    /// or because another book's item replaced its own, shows nothing, so a
    /// save never takes the AirPods and the media keys from the app or the
    /// book they were with. Both saves once published whatever the reader's
    /// state, so a stopped reader's save showed its book paused and took
    /// them (#1498). A save in the Library window, which reaches the reader
    /// as an update, follows the same rule (`showEditedMetadata()`).
    func showSavedMetadataInNowPlaying() {
        guard nowPlayingService.holdsMediaControls else { return }
        nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: isPlaybackActivelyAdvancing
        )
    }
}
