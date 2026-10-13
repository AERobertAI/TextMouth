import Foundation

// MARK: - Edited Text (FR05)

/// The book's edited text, and the moves of its places that the edit took,
/// kept by a reader still loading until its load ends
/// (`ReaderViewModel.editedTextWaitingForLoad`).
struct EditedTextWaitingForLoad {
    /// The edited text, parsed and indexed.
    let content: DocumentContent
    /// The moves of the book's saved places the edit took (T06's branch E);
    /// nil when it moved none.
    let movedPlaces: MovedPlaces?
}

/// How an open reader shows its book's text once the user has edited it in
/// their own editor and TextMouth has taken the edit (`BookTextEditor`).
///
/// The library sends the edited text, parsed and indexed, through the
/// readers' usual updates (`LibraryBookEvent.textReplaced`), after the
/// book's row has taken the edit's counts, together with the moves of the
/// book's saved places the edit took. The reader then shows the text in
/// place of the text it had, and its cursor, its own copy of the book's
/// places (its skipped headings), and its bookmark list follow their words
/// (T06's branch E): all silently, with nothing spoken or shown. Speech of
/// the old text stops, and starts again from the cursor when it was
/// playing.
extension ReaderViewModel {

    /// Shows `edited`, the book's text as the user edited it, in place of
    /// the text this reader shows, unless it shows that very text already.
    /// `movedPlaces` is what the edit moved of the book's saved places
    /// (nil for none), which this reader's own copies take too.
    ///
    /// A reader still loading keeps the text, with the moves, until loading
    /// ends, since what it is loading may be the text from before the edit.
    /// A reader whose load stopped over an edit that could not be taken
    /// opens the book with this text, now that an edit is taken: the text
    /// the library committed, parsed and indexed already, so nothing is read
    /// again; it takes the moves as any load does. A reader that shows the
    /// edited text already takes the moves only (a guarded no-op when it
    /// holds them).
    ///
    /// Otherwise the cursor is carried to its words in the edited text by the
    /// place relocator (`PlaceRelocator.relocate(_:from:to:)`) before
    /// anything changes, and the reader's copies of the book's places take
    /// the moves, each only where it still holds the place as it was, so a
    /// place the listener moved meanwhile stays. The reader's own cursor
    /// wins over the saved position's move.
    func showEditedText(_ edited: DocumentContent, movedPlaces: MovedPlaces? = nil) {
        guard !hasClosed, !isAudioBook else { return }
        if content == nil, !isLoading, loadHeldByTextEdit {
            loadHeldByTextEdit = false
            errorMessage = nil
            showLoadedContent(
                LoadedContent(
                    content: edited,
                    index: edited.contentIndex,
                    audioFiles: nil,
                    audioSegments: nil,
                    audioTags: nil,
                    shouldPersistContentIndex: false,
                    cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
                    movedPlaces: movedPlaces.map { [$0] } ?? []
                ),
                readFrom: book.filePath
            )
            return
        }
        guard !isLoading, let current = content else {
            editedTextWaitingForLoad = EditedTextWaitingForLoad(content: edited, movedPlaces: movedPlaces)
            return
        }
        guard !Self.showsSameText(current, as: edited) else {
            takeMovedPlaces(movedPlaces)
            return
        }

        // A book Where Am I? holds plays on too: one the announcement paused
        // as it played, or one it would start for a Play pressed during it
        // (`whereAmIWillPlayBook`). The stop below ends the announcement with
        // the book, which once left such a book stopped (REV12).
        let wasPlaying = (isCurrentlyPlaying && !isCurrentlyPaused) || whereAmIWillPlayBook
        // Where the cursor goes, found before anything changes, from the
        // words at the cursor in the text it is in. This runs on the main
        // actor, once per edit taken: the relocator is built only when the
        // cursor's words do not stand in the edited text, which costs about
        // 20 ms for a novel and 100 to 130 ms for a long book, in optimized
        // code.
        let carried = PlaceRelocator.relocate(
            TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset),
            from: current,
            to: edited
        )
        // The speech of the old text, its look-ahead, and what was prepared
        // from it all go: none of it is the book's any more.
        if isCurrentlyPlaying || isCurrentlyPaused || isWaitingForChapterSpeech {
            stop()
        }
        discardLookAhead()
        chapterSpeechCache.removeAll()

        // Assigning content also publishes its headings.
        content = edited
        // The reader's copies of the book's places take the edit's moves
        // (which may carry the cursor with the saved position), then the
        // cursor goes where its own words are: the reader's own cursor wins.
        takeMovedPlaces(movedPlaces)
        currentChapterIndex = carried.chapter
        currentCharacterOffset = carried.offset
        // The words the place the book opened at took were the old text's:
        // they are let go, or are the moved position's own where the cursor
        // is at it.
        noteLoadedTextForAnchors(cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        // This reader's sleep timer for the end of the heading waits for
        // the heading after the cursor in the edited text.
        if sleepTimerService.waitsForHeadingEnd(ownedBy: readerID) {
            sleepTimerNextHeading = headingAfterCursor
        }
        savePosition()
        refreshPlaybackUI(forceVisibleTextRefresh: true)
        if wasPlaying {
            play()
        } else {
            prepareOpenedChapterSpeech()
        }
    }

    /// Shows the edited text taken while this reader loaded, if any, with
    /// its moves of the book's places: called as loading ends.
    func showEditedTextWaitingForLoad() {
        guard let waiting = editedTextWaitingForLoad else { return }
        editedTextWaitingForLoad = nil
        showEditedText(waiting.content, movedPlaces: waiting.movedPlaces)
    }

    /// Whether `current`, the text a reader shows, is `edited` already: both
    /// were measured from the same content.md bytes, as a reader that
    /// loaded after the edit was taken shows it.
    nonisolated static func showsSameText(_ current: DocumentContent, as edited: DocumentContent) -> Bool {
        guard let shown = current.contentIndex.textCacheFingerprint?.cache.digest,
              let replacing = edited.contentIndex.textCacheFingerprint?.cache.digest else { return false }
        return shown == replacing
    }
}
