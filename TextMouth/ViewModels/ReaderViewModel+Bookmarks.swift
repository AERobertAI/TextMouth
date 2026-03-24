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

    /// Find a bookmark within the proximity threshold of the given position.
    /// Only matches bookmarks in the same chapter.
    func nearbyBookmark(chapterIndex: Int, characterOffset: Int) -> Bookmark? {
        let threshold = bookmarkProximityThreshold
        return bookmarks.first { bm in
            bm.chapterIndex == chapterIndex &&
            abs(bm.characterOffset - characterOffset) <= threshold
        }
    }

    /// Whether a bookmark exists near the current reading position
    var hasNearbyBookmark: Bool {
        nearbyBookmark(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset) != nil
    }

    /// Toggle a bookmark at the current position: if one exists nearby, remove it;
    /// otherwise add a new one. When adding, checks for overlap with existing
    /// bookmarks and adjusts position to avoid placing two bookmarks within
    /// each other's proximity zones.
    func toggleBookmarkAtCurrentPosition() {
        if let existing = nearbyBookmark(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset) {
            // Remove the nearby bookmark
            let number = existing.number
            removeBookmark(existing)
            announceToVoiceOver("Bookmark \(number) removed")
        } else {
            // Add a new bookmark, adjusting position if it would overlap with an existing one
            let adjustedOffset = adjustedBookmarkOffset(
                chapterIndex: currentChapterIndex,
                characterOffset: currentCharacterOffset
            )
            libraryViewModel.addBookmark(
                bookID: book.id,
                chapterIndex: currentChapterIndex,
                characterOffset: adjustedOffset,
                label: ""
            )
            bookmarks = libraryViewModel.bookmarksForBook(book.id)
            announceToVoiceOver("Bookmark \(bookmarks.count) added")
        }
    }

    /// Adjust a bookmark offset so it doesn't fall within the proximity zone
    /// of an existing bookmark in the same chapter. Nudges the position just
    /// outside the threshold of the nearest conflicting bookmark.
    private func adjustedBookmarkOffset(chapterIndex: Int, characterOffset: Int) -> Int {
        let threshold = bookmarkProximityThreshold
        let sameChapterBookmarks = bookmarks.filter { $0.chapterIndex == chapterIndex }

        // Check if any existing bookmark is too close
        guard let conflict = sameChapterBookmarks.first(where: {
            abs($0.characterOffset - characterOffset) <= threshold
        }) else {
            // No overlap — use the original position
            return characterOffset
        }

        // Nudge to just outside the threshold, in the direction away from the conflict
        if characterOffset >= conflict.characterOffset {
            return conflict.characterOffset + threshold + 1
        } else {
            return max(0, conflict.characterOffset - threshold - 1)
        }
    }

    /// Add a bookmark at the current reading position with an optional label
    func addBookmarkAtCurrentPosition(label: String = "") {
        libraryViewModel.addBookmark(
            bookID: book.id,
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            label: label
        )
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        announceToVoiceOver("Bookmark \(bookmarks.count) added")
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
            navigateTo(chapterIndex: next.chapterIndex, characterOffset: next.characterOffset)
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
            navigateTo(chapterIndex: prev.chapterIndex, characterOffset: prev.characterOffset)
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
        savePositionForReturn()
        navigateTo(chapterIndex: bookmark.chapterIndex, characterOffset: bookmark.characterOffset)
        autoPlayIfEnabled()
    }

    /// Navigate to a search result, saving current position for return
    func navigateToSearchResult(chapterIndex: Int, characterOffset: Int) {
        savePositionForReturn()
        navigateTo(chapterIndex: chapterIndex, characterOffset: characterOffset)
        autoPlayIfEnabled()
    }

    /// If the auto-play-on-navigate setting is enabled and playback is not active, start playing.
    func autoPlayIfEnabled() {
        guard settingsViewModel.autoPlayOnNavigate else { return }
        let isActive = isAudioBook
            ? (audioPlaybackService.isPlaying && !audioPlaybackService.isPaused)
            : (speechService.isSpeaking && !speechService.isPaused)
        if !isActive {
            togglePlayPause()
        }
    }

    /// Save current position so the user can return to it after browsing headings/bookmarks
    func savePositionForReturn() {
        savedChapterIndex = currentChapterIndex
        savedCharacterOffset = currentCharacterOffset
        hasSavedPosition = true
    }

    /// Return to the position saved before the last heading/bookmark navigation
    func returnToSavedPosition() {
        guard hasSavedPosition else { return }
        hasSavedPosition = false
        navigateTo(chapterIndex: savedChapterIndex, characterOffset: savedCharacterOffset)
        announceToVoiceOver("Returned to previous position")
    }

    // MARK: - Metadata Editing

    /// Save edited EPUB metadata. Optionally writes changes back to the EPUB file.
    func saveEPUBMetadata(_ metadata: EPUBMetadata, writeToFile: Bool) {
        epubMetadata = metadata

        book.title = metadata.title
        book.author = metadata.author

        if writeToFile && book.format == .epub {
            do {
                let url = URL(fileURLWithPath: book.filePath)
                let newHash = try EPUBParser.writeMetadata(metadata, to: url)
                book.md5Hash = newHash
                libraryViewModel.updateBookMetadata(book)
                announceToVoiceOver("Metadata saved to file")
            } catch {
                errorMessage = error.localizedDescription
                announceToVoiceOver("Failed to save metadata to file")
            }
        } else {
            libraryViewModel.updateBookMetadata(book)
            announceToVoiceOver("Metadata updated")
        }

        // Update NowPlaying with the new metadata
        nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: isCurrentlyPlaying && !isCurrentlyPaused
        )
    }

    /// Save edited audio metadata. Updates the book's title/author and persists
    /// the album, genre, and year fields to bookInfo.json inside the .tmb package.
    func saveAudioMetadata(_ metadata: AudioMetadata) {
        audioMetadata = metadata

        book.title = metadata.title
        book.author = metadata.artist
        book.audioAlbum = metadata.album
        book.audioGenre = metadata.genre
        book.audioYear = metadata.year

        libraryViewModel.updateBookMetadata(book)
        announceToVoiceOver("Metadata updated")

        // Update NowPlaying with the new metadata
        nowPlayingService.updateNowPlayingInfo(
            title: book.title,
            author: book.author,
            isPlaying: isCurrentlyPlaying && !isCurrentlyPaused
        )
    }
}
