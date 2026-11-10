import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
            // A book the library no longer holds has no bookmark to remove:
            // say so, as the add paths do, not that one was removed.
            guard libraryViewModel.bookByID(book.id) != nil else {
                announceBookmarkNotDone(Self.bookmarkNotRemovedAnnouncement(bookTitle: book.title))
                return
            }
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
            addBookmark(atOffset: adjustedOffset, label: "")
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
        addBookmark(atOffset: currentCharacterOffset, label: label)
    }

    /// Adds a bookmark at `offset` in the current chapter, keeping the words
    /// around it (T06, `anchorToSave(at:)`), tells VoiceOver which bookmark
    /// it made or that it made none, and returns it. The toggle and the
    /// panel's Add share it.
    ///
    /// - Returns: The bookmark added; nil when the library holds no record
    ///   of this book and so added nothing.
    @discardableResult
    private func addBookmark(atOffset offset: Int, label: String) -> Bookmark? {
        // The bookmarks saved before this one. Whichever bookmark is new
        // afterwards is the one added here, wherever the library placed it.
        let existingIDs = Set(libraryViewModel.bookmarksForBook(book.id).map(\.id))
        libraryViewModel.addBookmark(
            bookID: book.id,
            chapterIndex: currentChapterIndex,
            characterOffset: offset,
            label: label,
            anchor: anchorToSave(at: TextPlace(chapter: currentChapterIndex, offset: offset))
        )
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
        let added = bookmarks.first { !existingIDs.contains($0.id) }
        announceBookmarkAdded(added)
        return added
    }

    /// What VoiceOver says when no bookmark could be added because the
    /// library holds no record of the book, as when the book was removed
    /// while its reader was open. It does not say that nothing was changed:
    /// the reader's own list of bookmarks is emptied too.
    static func bookmarkNotAddedAnnouncement(bookTitle: String) -> String {
        "Could not add the bookmark: \u{201C}\(bookTitle)\u{201D} is no longer in the library."
    }

    /// What VoiceOver says when a bookmark could not be removed because the
    /// library holds no record of the book.
    static func bookmarkNotRemovedAnnouncement(bookTitle: String) -> String {
        "Could not remove the bookmark: \u{201C}\(bookTitle)\u{201D} is no longer in the library."
    }

    /// Says `sentence`, which tells that a bookmark command did nothing, a
    /// moment late: the bookmarks panel moves VoiceOver's focus a moment
    /// after an add, which cuts off words posted with the move, so the long
    /// sentence waits until the focus has settled (REV11 F6,
    /// `VoiceOverAnnouncer.afterSheetCloses`).
    private func announceBookmarkNotDone(_ sentence: String) {
        VoiceOverAnnouncer.afterSheetCloses { [weak self] in
            self?.announceToVoiceOver(sentence)
        }
    }

    /// Says which bookmark was added, by the number it was given, or that
    /// none was when `added` is nil. The number is the new bookmark's own,
    /// never a count of the bookmarks, so it names the bookmark that was
    /// made, and a command that added nothing never claims a bookmark. The
    /// sentence for none waits for the focus to settle
    /// (`announceBookmarkNotDone`).
    private func announceBookmarkAdded(_ added: Bookmark?) {
        if let added {
            announceToVoiceOver("Bookmark \(added.number) added")
        } else {
            announceBookmarkNotDone(Self.bookmarkNotAddedAnnouncement(bookTitle: book.title))
        }
    }

    /// Update the user-facing label on an existing bookmark
    func updateBookmarkLabel(_ bookmark: Bookmark, label: String) {
        libraryViewModel.updateBookmarkLabel(bookID: book.id, bookmarkID: bookmark.id, label: label)
        bookmarks = libraryViewModel.bookmarksForBook(book.id)
    }

    /// This book's bookmarks in the order they lie in the book: by chapter,
    /// then by place within the chapter, two at one place by their numbers.
    /// Next and Previous Bookmark go by this order. The numbers alone follow
    /// the order the bookmarks were made, so going by them passed over a
    /// bookmark made later at an earlier place.
    private var bookmarksInBookOrder: [Bookmark] {
        bookmarks.sorted { first, second in
            (first.chapterIndex, first.characterOffset, first.number)
                < (second.chapterIndex, second.characterOffset, second.number)
        }
    }

    /// Navigate to the nearest bookmark after the current position in the
    /// book (`bookmarksInBookOrder`), saying its number.
    func goToNextBookmark() {
        let cursor = (currentChapterIndex, currentCharacterOffset)
        guard let next = bookmarksInBookOrder.first(where: { ($0.chapterIndex, $0.characterOffset) > cursor }) else {
            return
        }
        navigatePreservingReturnPosition(chapterIndex: next.chapterIndex, characterOffset: next.characterOffset)
        announceToVoiceOver("Bookmark \(next.number)")
    }

    /// Navigate to the nearest bookmark before the current position in the
    /// book (`bookmarksInBookOrder`), saying its number.
    func goToPreviousBookmark() {
        let cursor = (currentChapterIndex, currentCharacterOffset)
        guard let previous = bookmarksInBookOrder.last(where: { ($0.chapterIndex, $0.characterOffset) < cursor }) else {
            return
        }
        navigatePreservingReturnPosition(chapterIndex: previous.chapterIndex, characterOffset: previous.characterOffset)
        announceToVoiceOver("Bookmark \(previous.number)")
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

    /// Moves the reader to a Search in Book result, saving the current
    /// position for Return and Go Back: the result of a transcript search to
    /// the start of the sentence holding the match, any other to the match.
    /// The one place that decides which move a result makes, for the Mac's
    /// sheet and the phone's.
    /// - Parameters:
    ///   - chapterIndex: The content unit (chapter) holding the match.
    ///   - characterOffset: The UTF-16 offset of the match in that unit's text.
    ///   - inTranscript: Whether the book searched is a transcript
    ///     (`BookSearchCorpus.timing` is not nil).
    func goToSearchResult(chapterIndex: Int, characterOffset: Int, inTranscript: Bool) {
        if inTranscript {
            navigateToTranscriptSearchResult(chapterIndex: chapterIndex, textOffset: characterOffset)
        } else {
            navigateToSearchResult(chapterIndex: chapterIndex, characterOffset: characterOffset)
        }
    }

    /// Whether Search in Book has a text to search: a text book that has
    /// loaded, or an audiobook with a transcript, whose text it searches.
    /// An audiobook without one has only spacing that counts time.
    var canSearchText: Bool {
        isAudioBook ? content?.transcript != nil : content != nil
    }

    /// Says why Search in Book has nothing to search in this loaded
    /// audiobook, in place of opening (`BookSearchWording.noTextToSearch`):
    /// that it has no transcript, or, for one whose text is not shown, why
    /// not. `hasTranscript` is whether the book has a transcript as the
    /// library's rows and the Book menu know it (`TranscribedBooks`), so the
    /// command it names, if any, is the one the menu offers. A reason the
    /// load found for the text not being shown means the book has a
    /// transcript whatever the rows have noted of it yet.
    ///
    /// `offersTranscription` is false on the iPhone, which cannot transcribe:
    /// the words then name no command and tell no one to transcribe.
    func announceNoTextToSearch(hasTranscript: Bool, offersTranscription: Bool = true) {
        announceToVoiceOver(BookSearchWording.noTextToSearch(
            bookTitle: book.title,
            canTranscribe: LibraryAudioCommand.isTranscribable(book),
            hasTranscript: hasTranscript || transcriptWithheld != nil,
            withheld: transcriptWithheld,
            offersTranscription: offersTranscription
        ))
    }

    /// The timing of the loaded audiobook's transcript over its audio
    /// chapters; nil for a text book and for an audiobook without a transcript.
    private var transcriptSearchTiming: BookSearchTiming? {
        guard isAudioBook, let content, let transcript = content.transcript else { return nil }
        return .forTranscript(transcript, audioChapters: content.chapters)
    }

    /// What Search in Book searches, copied so the search can run off the
    /// main actor: a text book's chapters, with its headings to name where
    /// each match is; or a transcribed audiobook's transcript, by audio
    /// chapter, timed, and named by chapter title alone, since the reader's
    /// audiobook headings count audio time, not transcript text. Nil when
    /// `canSearchText` is false.
    var searchCorpus: BookSearchCorpus? {
        guard canSearchText, let content else { return nil }
        if let timing = transcriptSearchTiming {
            return BookSearchCorpus(
                chapterTexts: timing.transcript.chapters.map(\.text),
                chapterTitles: content.chapters.map(\.title),
                headings: [],
                bookTitle: book.title,
                timing: timing
            )
        }
        return BookSearchCorpus(
            chapterTexts: content.chapters.map(\.text),
            chapterTitles: content.chapters.map(\.title),
            headings: headings,
            bookTitle: book.title
        )
    }

    /// Navigate to a result of a transcript search: the audio moves to the
    /// start of the sentence holding the match, saving the current position
    /// for Return and Go Back. The move is announced once the sheet has
    /// closed (`announcePendingJump()`). Does nothing for a book without a
    /// transcript.
    func navigateToTranscriptSearchResult(chapterIndex: Int, textOffset: Int) {
        guard let timing = transcriptSearchTiming else { return }
        let audioOffset = timing.transcript.audioOffset(atTextOffset: textOffset, inChapter: chapterIndex)
        guard navigatePreservingReturnPosition(chapterIndex: chapterIndex, characterOffset: audioOffset) else { return }
        autoPlayIfEnabled()
        // The place is named as a search result names it: by its chapter's
        // title, unless that is empty or only repeats the book's title.
        let location = BookSearchView.locationTitles(
            of: [(chapterIndex: chapterIndex, characterOffset: textOffset)],
            headings: [],
            chapterTitles: content?.chapters.map(\.title) ?? [],
            bookTitle: book.title
        ).first ?? nil
        pendingJumpAnnouncement = BookSearchWording.movedTo(
            time: timing.time(chapterIndex: chapterIndex, characterOffset: textOffset),
            location: location
        )
    }

    /// Say where a transcript search result took the reader, if one did, and
    /// forget it. Called when the search sheet has gone.
    func announcePendingJump() {
        guard let announcement = pendingJumpAnnouncement else { return }
        pendingJumpAnnouncement = nil
        announceToVoiceOver(announcement)
    }

    /// Go Back (the Navigate menu's): return to the position saved before the
    /// last jump, or say there is none.
    func goBack() {
        if hasSavedPosition {
            returnToSavedPosition()
        } else {
            announceToVoiceOver(BookSearchWording.nothingToGoBackTo)
        }
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
            // The words every metadata editor's save uses for such a book.
            announceToVoiceOver(MetadataEditorWording.notInLibrary(title: book.title))
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
