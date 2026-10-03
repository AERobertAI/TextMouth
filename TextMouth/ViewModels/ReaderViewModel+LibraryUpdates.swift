import Foundation

// MARK: - Library Updates (TODO P10)

/// How an open reader keeps its copy of its book current while the library
/// edits, renames, or moves the book from another window.
///
/// A reader takes its own copy of its book when it opens. The library
/// publishes every change of what readers show or use of a book (where its
/// files are, its editable metadata, and its analysis; see
/// `Book.LibraryFields`) through `LibraryBookUpdates`, each with the book's
/// next revision. The reader applies each update it has not applied yet:
/// its copy takes the library's fields and keeps everything that is the
/// reader's own, and whatever the reader shows from those fields follows.
/// Nothing is reloaded, and playback goes on.
///
/// Before the library moves the book's package on disk, it says so, and
/// audio that is playing stops reading the book's files until the move is
/// over, then plays on from the same place.
extension ReaderViewModel {

    /// Audio set aside while the book's package moves: playing when the
    /// move was announced, at `volume`, which a sleep timer may be fading.
    struct AudioPausedForMove: Equatable {
        let volume: Float
    }

    /// Handles one event the library sent about this reader's book. A
    /// closed reader has nothing left to keep current.
    func handleLibraryEvent(_ event: LibraryBookEvent) {
        guard !hasClosed else { return }
        switch event {
        case .packageWillMove:
            pauseAudioForPackageMove()
        case .updated(let update):
            applyLibraryUpdate(update)
        case .packageMoveEnded:
            resumeAudioAfterPackageMove()
        }
    }

    /// Applies `update` when it is about this reader's book and newer than
    /// the last update applied; an older or repeated one changes nothing.
    ///
    /// The reader's copy of the book takes the library's fields from the
    /// update's row (`Book.LibraryFields`), so later saves, Continue to Next
    /// Book, and everything the reader shows start from the book as the
    /// library has it. The reader's own state (its cursor, bookmarks,
    /// voice, speed, and other settings, which it writes through to the
    /// library itself) stays as it is.
    func applyLibraryUpdate(_ update: LibraryBookUpdate) {
        guard update.book.id == book.id, update.revision > appliedLibraryRevision else { return }
        appliedLibraryRevision = update.revision
        let previous = book
        book.libraryFields = update.book.libraryFields
        if book.filePath != previous.filePath {
            followMovedFiles()
        }
        if book.editableMetadata != previous.editableMetadata {
            showEditedMetadata()
        }
    }

    // MARK: - Moved Files

    /// Points everything the reader plays from at the book's files where
    /// they are now, after the library moved them: a move to another
    /// folder, a rename or move of a folder above the book, a data
    /// directory move, or a repair. A single-file book and a segmented
    /// book's clips are found from the book's own path when they play; a
    /// multi-file book's chapter files are found again here.
    ///
    /// An audiobook playing from its working copy (FR02) plays on from it
    /// undisturbed, since the copy did not move; the copy now came from the
    /// package where it is, so the files named by the book's new path still
    /// find their copies.
    private func followMovedFiles() {
        if !audioChapterFiles.isEmpty, let index = content?.contentIndex {
            audioChapterFiles = audioChapterFilesAtCurrentLocation(audioChapterFiles, index: index)
        }
        if playsFromWorkingCopy {
            workingCopyFollowsMovedPackage()
            return
        }
        retargetAudioPlayback()
    }

    /// `files`, a multi-file audiobook's chapter files, found under the
    /// book's path as it is now: each chapter's file as `index` records it,
    /// relative to that path, just as opening the book finds them. `files`
    /// is kept when the index does not name a file for every chapter, which
    /// the index of a book with chapter files always does.
    func audioChapterFilesAtCurrentLocation(_ files: [String], index: BookContentIndex) -> [String] {
        index.resolvedAudioFilePaths(relativeTo: URL(fileURLWithPath: book.filePath)) ?? files
    }

    /// Moves the audio player off a file the library has moved. Playing
    /// audio plays on at once from the same place in the book's files where
    /// they are now. Paused audio stays paused, and resuming plays from the
    /// files where they are then. With no file loaded, the next play finds
    /// the files where they are anyway, and audio set aside for a package
    /// move plays on from the new place when the move ends.
    private func retargetAudioPlayback() {
        guard isAudioBook, audioPausedForMove == nil, audioPlaybackService.loadedURL != nil else { return }
        if audioPlaybackService.isPlaying && !audioPlaybackService.isPaused {
            restartAudioAtCursor(volume: audioPlaybackService.intendedVolume)
        } else {
            restartPlaybackBackendOnNextResume = true
        }
    }

    // MARK: - Package Moves

    /// The library is about to move the book's package. Audio that is
    /// playing stops now, releasing the file it plays, so nothing reads the
    /// book's files while they move or after they are gone; the reader goes
    /// on showing Playing, its cursor where the audio stopped. Paused audio
    /// reads nothing and is left alone. Speech reads no files as it plays,
    /// and audio playing from the book's working copy (FR02) reads none of
    /// the package's files, so it plays on through the move.
    private func pauseAudioForPackageMove() {
        guard isAudioBook, audioPausedForMove == nil, !playsFromWorkingCopy,
              audioPlaybackService.isPlaying, !audioPlaybackService.isPaused else { return }
        audioPausedForMove = AudioPausedForMove(volume: audioPlaybackService.intendedVolume)
        audioPlaybackService.stop()
    }

    /// The move announced before is over. Audio set aside for it plays on
    /// from the cursor, from wherever the book's files now are: the new
    /// place, which the library's update has already given the reader, or
    /// the old one when the move was put back.
    private func resumeAudioAfterPackageMove() {
        guard let paused = audioPausedForMove else { return }
        audioPausedForMove = nil
        restartAudioAtCursor(volume: paused.volume)
    }

    /// Plays the cursor's chapter again from the cursor, loading its audio
    /// from wherever the book's files are now, at `volume`, the volume it
    /// played at, which a sleep timer may be fading. The listening session,
    /// the sleep timer, and the media controls carry on as they were.
    private func restartAudioAtCursor(volume: Float) {
        audioPlaybackService.stop()
        audioPlaybackService.setVolume(volume)
        playAudioChapter()
    }

    /// Shows the book's metadata as the library now has it wherever the
    /// reader keeps metadata of its own: the values its metadata editor
    /// starts from, so a later save there cannot put back what the library
    /// replaced, and Now Playing. The window title, Where Am I?, and the
    /// reader's announcements read the book itself.
    private func showEditedMetadata() {
        if let epubMetadata {
            self.epubMetadata = book.mergingEditableEPUBMetadata(epubMetadata)
        }
        if let audioMetadata {
            self.audioMetadata = book.mergingEditableAudioMetadata(audioMetadata)
        }
        // Now Playing names this reader's book only while it plays or is
        // paused; a stopped reader has nothing there to correct, and
        // updating it would put a stopped book back.
        if isCurrentlyPlaying || isCurrentlyPaused {
            nowPlayingService.updateNowPlayingInfo(
                title: book.title,
                author: book.author,
                isPlaying: isPlaybackActivelyAdvancing
            )
        }
    }
}
