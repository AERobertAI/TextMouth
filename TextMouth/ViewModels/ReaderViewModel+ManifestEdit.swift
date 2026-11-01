import Foundation

// MARK: - A Rearranged Audiobook of Tracks (FR17)

/// How an open audiobook's reader follows an edit of its manifest that
/// TextMouth has taken (`BookManifestEditor`, item 6).
///
/// The library sends the edit, already committed to the book's record,
/// through the readers' usual updates (`LibraryBookEvent.tracksRearranged`),
/// after the book's row has taken the edit's analysis and the moves of its
/// places. The reader then shows the new headings, with its cursor on the
/// same track at the same time: each chapter is mapped to its file, and the
/// file to its chapter now (`TrackPlaces.chapterMap`). Nothing stops: a
/// playing reader plays on in the same file without a break, its play under
/// way now ends as the play of the track's new chapter, and the file named
/// to follow it is the next track in the new order, so the book goes on to
/// that track. The pauses between tracks become the edited manifest's.
extension ReaderViewModel {

    /// Shows the book as `edit` arranges it, unless the reader shows that
    /// arrangement already. A reader still loading keeps the edit until its
    /// load ends, since what it loads may be the arrangement from before.
    /// A reader that shows the arrangement already, having loaded it after
    /// the edit was committed, takes the moves of its places only (a
    /// guarded no-op when it holds them).
    func showRearrangedTracks(_ edit: BookManifestEdit) {
        guard !hasClosed, isAudioBook else { return }
        guard !isLoading, let current = content else {
            manifestEditWaitingForLoad = edit
            return
        }
        let shown = current.contentIndex
        guard shown.chapters.map(\.audioFilePath) != edit.index.chapters.map(\.audioFilePath)
            || shown.allHeadings.map(\.text) != edit.index.allHeadings.map(\.text)
            || shown.allHeadings.map(\.level) != edit.index.allHeadings.map(\.level)
            || chapterPauses != edit.pauses
        else {
            takeMovedTrackPlaces(edit.movedPlaces)
            return
        }
        guard var rearranged = edit.index.makeAudioDocumentContent(title: book.title, author: book.author) else { return }
        rearranged.transcript = edit.transcript

        // Where the cursor goes, found before anything changes: the chapter
        // playing its track now, at the same time into it.
        let map = TrackPlaces.chapterMap(from: shown, to: edit.index)
        let chapter = map[currentChapterIndex] ?? min(currentChapterIndex, max(0, edit.index.chapters.count - 1))
        let playUnderWay = isCurrentlyPlaying || isCurrentlyPaused

        // Assigning content also publishes its headings.
        content = rearranged
        audioChapterFiles = audioChapterFilesAtCurrentLocation(audioChapterFiles, index: edit.index)
        chapterPauses = edit.pauses
        // The reader's copies of the book's places take the edit's moves,
        // then the cursor goes to its own track: the reader's cursor wins.
        takeMovedTrackPlaces(edit.movedPlaces)
        currentChapterIndex = chapter

        // The file playing ends as the play of its track's new chapter, in
        // the same generation, so its end goes on to the next track in the
        // new order; that track's file is named to follow it.
        if playUnderWay {
            listenForAudioEnd(of: cursorChapterPlay)
        }
        nameFileAfterCurrentChapter()
        // This reader's sleep timer for the end of the heading waits for
        // the heading after the cursor in the new arrangement.
        refreshSleepTimerHeading()
        savePosition()
        refreshPlaybackUI(forceVisibleTextRefresh: true)
    }

    /// Shows the arrangement an edit of the manifest gave while this reader
    /// loaded, if any: called as loading ends.
    func showManifestEditWaitingForLoad() {
        guard let waiting = manifestEditWaitingForLoad else { return }
        manifestEditWaitingForLoad = nil
        showRearrangedTracks(waiting)
    }

    // MARK: Edits Made Outside Edit Manifest (FR18)

    /// Hands what the look at this audiobook's manifest found as it loaded
    /// (`readContent(of:audioTagsFrom:readingTexts:)`) to the manifest
    /// editor once the book shows: an edit taken is given to the library,
    /// which refreshes the book's row and its other open readers, and
    /// announced, "Manifest updated"; one refused is announced once for the
    /// same bytes, the book showing as it was. Nothing for nil.
    func reportManifestLookAtLoad(_ found: BookManifestEditCheck?) {
        guard let found else { return }
        manifestEditor.handle(found, for: book.id, in: libraryViewModel)
    }

    /// Looks for an edit of this audiobook of tracks' manifest made outside
    /// Edit Manifest while the book is open, as TextMouth becomes active,
    /// off the main thread: the book as the library holds it, and the
    /// pauses this reader keeps between its tracks, so an edit of the
    /// pauses alone is taken too. Nothing while the book loads, since its
    /// load looks, and nothing for any other book.
    func lookForOutsideManifestEdit() {
        guard !hasClosed, !isLoading, content?.contentIndex.audioLayout == .multiFile else { return }
        manifestEditor.lookForOutsideEdit(
            of: libraryViewModel.bookByID(book.id) ?? book,
            showingPauses: chapterPauses,
            in: libraryViewModel
        )
    }
}
