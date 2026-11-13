import AVFoundation
import Combine
import XCTest
@testable import TextMouth

/// An open reader keeps up with what the library does to its book from
/// another window (TODO P10): a metadata edit, a move to another folder, a
/// rename of the folder holding it, and a move of the whole data directory.
///
/// After each change, everything the reader shows or uses must match the
/// library's row: the title and author it shows (the window title, Now
/// Playing, Where Am I?) and offers its metadata editor, the book's folder
/// and file path, the audio files it plays from, and the file its player
/// holds. Whatever it saves afterwards must land in the package where the
/// book is now. Each check collects every reader field left stale, so a
/// failure names all of them at once.
@MainActor
final class ReaderRefreshTests: XCTestCase {

    // MARK: - Reproduction

    /// A text book open in a reader is renamed and credited to another
    /// author in the library's metadata editor, moved to another folder,
    /// and then has that folder renamed, all through the library model as
    /// the Library window does. The reader must show and use the book as
    /// the library now has it after each step; a bookmark added and edited
    /// and a position saved afterwards land in the package where the book
    /// is now, no old package comes back, and reopening the book shows the
    /// new metadata at the saved position.
    func testTextReaderFollowsALibraryEditMoveAndFolderRename() throws {
        let world = try makeIntegrationWorld("Reader Refresh Text")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let shelf = BookFolder(name: "Shelf", parentPath: world.folder.path)
        world.library.library.folders = [BookFolder(name: world.folder.path), shelf]
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        var stale: [String] = []

        // The Library window's metadata editor renames the book and credits
        // another author, saving to the library only.
        let opened = try XCTUnwrap(reader.epubMetadata, "The reader read no EPUB metadata")
        var edited = opened
        edited.title = Self.revisedTitle
        edited.author = Self.revisedAuthor
        let save = world.library.saveEPUBMetadata(edited, openedAs: opened, for: book, writingToFile: false)
        XCTAssertNotNil(save.savedBook, save.message)
        stale += staleFields(of: reader, in: world.library, after: "the metadata edit")

        // Move to Folder… moves the book into Shelf.
        let packageBeforeMove = try row(of: book, in: world.library).tmbDirectory
        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: shelf.fullPath) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        stale += staleFields(of: reader, in: world.library, after: "the move to Shelf")

        // Rename Folder… renames Shelf to Stacks, which moves the package again.
        let packageBeforeRename = try row(of: book, in: world.library).tmbDirectory
        let rename = outcome { await world.library.renameFolderReturningOutcome(shelf, to: "Stacks") }
        XCTAssertTrue(rename.succeeded, rename.failureMessage ?? "")
        stale += staleFields(of: reader, in: world.library, after: "the folder rename")

        XCTAssertTrue(stale.isEmpty, Self.report(stale))

        // A bookmark added and then edited, and a position saved, after the
        // moves all land in the package where the book is now.
        reader.navigateTo(chapterIndex: 1, characterOffset: 4)
        let bookmark = try XCTUnwrap(reader.addBookmarkAtCurrentPosition(label: "Neap tide"))
        reader.updateBookmarkLabel(bookmark, label: "Neap tide, second reading")
        reader.savePosition()
        LibraryPersistenceService.flushPendingSave()
        let current = try row(of: book, in: world.library)
        let record = try BookInfo.load(from: current.tmbDirectory)
        XCTAssertEqual(record.bookmarks.map(\.id), [bookmark.id], "The bookmark is not in the book's package")
        XCTAssertEqual(record.bookmarks.first?.label, "Neap tide, second reading")
        XCTAssertEqual(record.state.readingPosition?.chapterIndex, 1)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 4)
        XCTAssertEqual(record.metadata.title, Self.revisedTitle)
        for old in [packageBeforeMove, packageBeforeRename] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: old.path),
                "A write recreated the package the book left at \(Self.displayPath(old.path))"
            )
        }

        // Reopening the book from the library shows the new metadata and
        // continues from the saved position, with the bookmark.
        reader.close()
        let reopened = world.openReader(for: try row(of: book, in: world.library))
        waitForReaderToLoad(reopened)
        XCTAssertNil(reopened.errorMessage, "The moved book did not reopen")
        XCTAssertEqual(reopened.book.title, Self.revisedTitle)
        XCTAssertEqual(reopened.book.author, Self.revisedAuthor)
        XCTAssertEqual(reopened.epubMetadata?.title, Self.revisedTitle)
        XCTAssertEqual(reopened.epubMetadata?.author, Self.revisedAuthor)
        XCTAssertEqual(reopened.currentChapterIndex, 1)
        XCTAssertEqual(reopened.currentCharacterOffset, 4)
        XCTAssertEqual(reopened.bookmarks.map(\.label), ["Neap tide, second reading"])
    }

    /// An audiobook of two tracks plays when the library moves it to
    /// another folder. The reader must name the book's new files, its
    /// player must not hold a file that no longer exists, and moving on to
    /// the second track must play it from where the book is now.
    func testPlayingAudioReaderFollowsAMoveOfItsBook() throws {
        let world = try makeIntegrationWorld("Reader Refresh Audio Move")
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Soundings",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")

        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        var stale = staleFields(of: reader, in: world.library, after: "the move while playing")

        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        if let message = reader.errorMessage {
            stale.append("after the move, the second track could not play: \(message)")
        }
        XCTAssertTrue(stale.isEmpty, Self.report(stale))
        reader.stop()
    }

    /// While an audiobook is open, the Library window's editor renames it.
    /// The reader must show the new title and offer it in its own metadata
    /// editor, so that editor, opened afterwards to change only the genre,
    /// saves the genre without putting the old title back.
    func testReaderMetadataEditorKeepsTheLibrarysNewerTitle() throws {
        let world = try makeIntegrationWorld("Reader Refresh Audio Metadata")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")

        let original = try row(of: book, in: world.library)
        world.library.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: original.title], saved: [.title: "Breakwater Soundings, Second Survey"]),
            of: book.id
        )
        var stale = staleFields(of: reader, in: world.library, after: "the library's edit")

        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        var metadata = opened
        metadata.genre = "Field Recording"
        reader.saveAudioMetadata(metadata, openedAs: opened)

        let saved = try row(of: book, in: world.library)
        if saved.title != "Breakwater Soundings, Second Survey" {
            stale.append("the reader's own metadata save put back the title \"\(saved.title)\"")
        }
        XCTAssertEqual(saved.audioGenre, "Field Recording")
        XCTAssertTrue(stale.isEmpty, Self.report(stale))
    }

    /// An audiobook plays while the data directory moves, as Change
    /// Location… moves it. The library's half of that move is driven here,
    /// `TextMouthPaths.moveDataDirectory(to:library:)`: it copies the data
    /// directory and gives the library's books paths in the copy. (Change
    /// Location… also records the new location in the shared config.json,
    /// which the hosted app watches, so the whole command is not run.) The
    /// copy keeps the original, so nothing is missing; the reader must
    /// still play the book's files from where the library now has them.
    func testPlayingAudioReaderFollowsADataDirectoryMove() throws {
        let world = try makeIntegrationWorld("Reader Refresh Data Directory")
        let book = try world.makeSilentAudioBook(
            title: "Estuary Survey",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")
        // Every queued write is made first, so the copy is made of settled files.
        LibraryPersistenceService.flushPendingSave()
        // The move takes this process's data directory with it (TODO S04);
        // the destination's helper puts it back, and the location the move
        // records in the sandbox's preferences, when the test ends.
        let destination = try makeDataDirectoryMoveDestination("ReaderRefreshMovedData")

        try TextMouthPaths.moveDataDirectory(to: destination, library: &world.library.library)

        let moved = try row(of: book, in: world.library)
        XCTAssertTrue(
            moved.filePath.hasPrefix(destination.standardizedFileURL.path + "/"),
            "The library does not name the copy: \(Self.displayPath(moved.filePath))"
        )
        let stale = staleFields(of: reader, in: world.library, after: "the data directory move")
        XCTAssertTrue(stale.isEmpty, Self.report(stale))
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not go on")
        reader.stop()
    }

    // MARK: - Audio from Moved Files

    /// Paused audio stays paused when the library moves its book, and
    /// resuming plays from where the book's files are now, at the place it
    /// was paused.
    func testPausedAudioResumesFromTheMovedFiles() throws {
        let world = try makeIntegrationWorld("Reader Refresh Paused Audio")
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Soundings",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.play()
        reader.pause()
        XCTAssertTrue(reader.isCurrentlyPaused)

        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        XCTAssertTrue(reader.isCurrentlyPaused, "The move ended the pause")
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "The move started or stopped the player")

        reader.togglePlayPause()

        XCTAssertNil(reader.errorMessage)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Resuming did not play")
        XCTAssertFalse(reader.audioPlaybackService.isPaused, "Resuming did not play")
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: book, in: world.library).filePath),
            "Resuming played from somewhere other than the moved files"
        )
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 5)
        XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.001)
        reader.stop()
    }

    /// A segmented book, as a DAISY book plays, is in a heading whose clips
    /// run across three files when the library moves it. Playback goes on
    /// from the same place in the moved package, and seeking to a clip in
    /// another file loads that file from the moved package too.
    func testSegmentedAudioPlaysItsClipsFromTheMovedPackage() throws {
        let world = try makeIntegrationWorld("Reader Refresh Segmented Audio")
        let book = try world.makeSegmentedAudioBook(
            title: "Harbour Soundings",
            files: ["intro.wav": 1, "a.wav": 1, "b.wav": 0.75, "c.wav": 1, "d.wav": 1],
            sections: [
                AudioSegment(title: "Opening", file: "intro.wav", startTime: 0, endTime: 1),
                try XCTUnwrap(AudioSegment(title: "Harbour Survey", clips: [
                    AudioClip(file: "a.wav", startTime: 0.5, endTime: 1),
                    AudioClip(file: "b.wav", startTime: 0, endTime: 0.75),
                    AudioClip(file: "c.wav", startTime: 0.25, endTime: 1)
                ])),
                AudioSegment(title: "Closing", file: "d.wav", startTime: 0, endTime: 1)
            ],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 2)
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertEqual(reader.audioSegments.count, 3, "The book did not open as a segmented book")
        reader.play()
        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "a.wav")

        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")

        let movedFolder = Self.standardizedPath(try row(of: book, in: world.library).filePath)
        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "a.wav")
        XCTAssertEqual(Self.folderPath(of: reader.audioPlaybackService.loadedURL), movedFolder)
        XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.2, accuracy: 0.001)
        XCTAssertTrue(reader.isCurrentlyPlaying)

        // 0.8 seconds into the heading lies in its second clip, in b.wav.
        reader.navigateTo(chapterIndex: 1, characterOffset: 8)

        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "b.wav")
        XCTAssertEqual(Self.folderPath(of: reader.audioPlaybackService.loadedURL), movedFolder)
        reader.stop()
    }

    // MARK: - Saving Around a Move

    /// A position saved just before the library moves the book waits half a
    /// second to be written, and the move overtakes it. The move writes the
    /// book's record, that position included, in the package where the book
    /// now is, and the waiting write, aimed at the old package, is dropped
    /// rather than bringing that package back.
    func testAPositionSavedJustBeforeAMoveNeverRecreatesTheOldPackage() throws {
        let world = try makeIntegrationWorld("Reader Refresh Queued Save")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        LibraryPersistenceService.flushPendingSave()
        let oldPackage = book.tmbDirectory

        // Navigating saves the position, written half a second later.
        reader.navigateTo(chapterIndex: 2, characterOffset: 3)
        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        LibraryPersistenceService.flushPendingSave()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldPackage.path),
            "The waiting write brought the old package back"
        )
        let record = try BookInfo.load(from: try row(of: book, in: world.library).tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.chapterIndex, 2)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 3)
    }

    // MARK: - Playback Around Package Moves

    /// An audiobook plays when the library moves it to another folder. While
    /// its package moves on disk, nothing plays from it: the player holds no
    /// file. Once the move is over, playback goes on from the same place in
    /// the moved package, still showing Playing.
    func testAudioStopsReadingBeforeItsPackageMovesAndPlaysOnAtTheSamePlace() throws {
        let playing = try openPlayingAudiobook("Reader Refresh Audio Before Move")

        let duringMove = try moveToShelf(playing) {}

        XCTAssertNil(duringMove.loadedURL, "The player held a file while its package moved")
        XCTAssertFalse(duringMove.isPlaying, "Audio played while its package moved")
        try assertPlaysOnFromTheMovedPackage(playing)
        playing.reader.stop()
    }

    /// A package move that fails is put back, and audio that was playing
    /// when it started plays on from the same place in the book's files,
    /// where they still are, with no error.
    func testAudioPlaysOnFromTheOldPlaceWhenAMoveFails() throws {
        let world = try makeIntegrationWorld("Reader Refresh Failed Move")
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Soundings",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.play()
        let duringMove = PlayerObservation()

        XCTAssertThrowsError(try world.library.commitLibraryTransition(
            Self.library(world.library.library, moving: book.id, to: "\(world.folder.path)/Shelf"),
            affectedBookIDs: [book.id],
            disk: observingDisk(reader, into: duringMove, failing: true)
        ))

        XCTAssertEqual(duringMove.moves, 1)
        XCTAssertNil(duringMove.loadedURL, "The player held a file while its package moved")
        XCTAssertEqual(try row(of: book, in: world.library).folderPath, world.folder.path, "The failed move was kept")
        XCTAssertEqual(reader.book.filePath, book.filePath)
        XCTAssertNil(reader.errorMessage)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not go on after the failed move")
        XCTAssertEqual(Self.folderPath(of: reader.audioPlaybackService.loadedURL), Self.standardizedPath(book.filePath))
        XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.001)
        reader.stop()
    }

    /// A capitalization-only rename of the folder holding a playing
    /// audiobook renames the folder's directory in place, before the
    /// library's transition runs. The book's readers hear that its package
    /// will move while the directory still has its old spelling, the player
    /// holds no file when the library publishes the new path, and playback
    /// goes on from the same place under the new spelling once the rename
    /// is done.
    func testRespellingAPlayingBooksFolderStopsItsAudioUntilTheRenameIsDone() throws {
        let world = try makeIntegrationWorld("Reader Refresh Respelled Folder")
        let shelf = BookFolder(name: "shelf", parentPath: world.folder.path)
        world.library.library.folders = [BookFolder(name: world.folder.path), shelf]
        let created = try world.makeSilentAudioBook(
            title: "Breakwater Soundings",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let move = outcome { await world.library.moveBooksReturningOutcome([created], toFolder: shelf.fullPath) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        let book = try row(of: created, in: world.library)
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start")

        let log = MoveEventLog()
        let folder = world.folder
        log.subscription = world.library.bookUpdates.events(for: book.id).sink { [weak log, weak reader] event in
            switch event {
            case .packageWillMove:
                log?.entries.append("will move")
                log?.listingWhenAnnounced = (try? folder.entries()) ?? []
            case .updated:
                log?.entries.append("updated")
                log?.playerFileWhenUpdated = reader?.audioPlaybackService.loadedURL
            case .packageMoveEnded:
                log?.entries.append("move ended")
            case .textReplaced:
                log?.entries.append("text replaced")
            case .transcriptReplaced:
                log?.entries.append("transcript replaced")
            case .tracksRearranged:
                log?.entries.append("tracks rearranged")
            }
        }
        defer { log.subscription?.cancel() }

        let rename = FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
            outcome { await world.library.renameFolderReturningOutcome(shelf, to: "Shelf") }
        }

        XCTAssertTrue(rename.succeeded, rename.failureMessage ?? "")
        XCTAssertEqual(log.entries, ["will move", "updated", "move ended"])
        XCTAssertTrue(log.listingWhenAnnounced.contains("shelf"), "The directory was renamed before readers heard")
        XCTAssertNil(log.playerFileWhenUpdated, "The player held a file while the folder was renamed")
        XCTAssertTrue(try world.folder.entries().contains("Shelf"))
        XCTAssertEqual(reader.book.folderPath, "\(world.folder.path)/Shelf")
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not go on after the rename")
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: book, in: world.library).filePath)
        )
        XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.001)
        reader.stop()
    }

    // MARK: - Listening During a Package Move
    //
    // A move made off the main thread (`performLibraryTransition`) leaves
    // the main thread free while the package moves, so anything the
    // listener or the app does can come between the two events of the move.
    // That cannot be caused by hand: these tests run the command inside the
    // disk's move of `commitLibraryTransition`, which runs on the main
    // thread between the same two events.

    /// A sleep timer set to start playback while the library moves the
    /// package of the audiobook playing leaves the audio set aside for the
    /// move to the move's end: nothing is loaded from the package while it
    /// moves, no play sound is made, and once the move is over the audio
    /// plays on, started once, from the same place in the moved package,
    /// the timer running. Before, the timer's play took the book for one
    /// not playing and played the chapter from the moving files, with the
    /// play sound (REV13 2).
    func testASleepTimerStartingPlaybackDuringAMoveLeavesTheAudioToTheMovesEnd() throws {
        preserveSleepTimers()
        let playing = try openPlayingAudiobook("Reader Refresh Timer During Move")
        let reader = playing.reader
        let generationBefore = reader.chapterPlaybackGeneration

        let duringMove = try moveToShelf(playing) {
            reader.startSleepTimer(duration: .minutes(15), startPlaybackIfNeeded: true)
        }

        XCTAssertNil(duringMove.loadedURL, "The timer's play loaded the chapter from the moving package")
        XCTAssertFalse(duringMove.isPlaying, "Audio played while its package moved")
        XCTAssertEqual(playing.sounds.played, [], "The timer's play made the play sound")
        XCTAssertTrue(reader.sleepTimerService.isActive, "The timer does not run")
        try assertPlaysOnFromTheMovedPackage(playing)
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 1, "The chapter did not start exactly once")
        reader.cancelSleepTimer()
        reader.stop()
    }

    /// Where Am I? pressed while the library moves the package of the
    /// audiobook playing finds its audio set aside, waiting rather than
    /// playing, and pauses nothing. The move's end, while the announcement
    /// still speaks, holds the audio for the announcement's end rather than
    /// play it under the announcement, the reader showing Playing; and once
    /// the announcement's end sound has played, the audio plays on, started
    /// once and with no play sound, from the same place in the moved
    /// package. Before, the move's end restarted the audio at once, under
    /// the announcement (REV13 2).
    func testWhereAmIPressedDuringAMoveHoldsTheAudioUntilTheAnnouncementEnds() throws {
        let playing = try openPlayingAudiobook("Reader Refresh Where Am I During Move")
        let reader = playing.reader
        var announcements: [AVSpeechUtterance] = []
        reader._whereAmIUtteranceRecorderForTesting = { announcements.append($0) }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        let generationBefore = reader.chapterPlaybackGeneration

        _ = try moveToShelf(playing) {
            reader.whereAmI()
        }

        XCTAssertTrue(reader.isWhereAmISpeaking, "Where Am I? does not speak")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The audio played under the announcement")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI, "The move's end did not hold the audio for the announcement")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader does not show Playing")
        XCTAssertFalse(reader.isCurrentlyPaused, "The reader shows paused")
        let announcement = try XCTUnwrap(announcements.last, "No announcement was handed over")
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        XCTAssertTrue(waitUntil(timeout: 5) { !reader.isWhereAmISpeaking }, "The announcement did not end")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The audio played before the end sound")

        endSound.passEndSound()

        try assertPlaysOnFromTheMovedPackage(playing)
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 1, "The chapter did not start exactly once")
        XCTAssertEqual(playing.sounds.played, [.whereAmIStart, .whereAmIEnd])
        reader.stop()
    }

    /// Where Am I? pressed while the library moves the package of the
    /// audiobook playing, whose announcement ends by itself before the move
    /// does, leaves the audio held for the end sound: the move's end, in the
    /// moment the end sound plays, starts nothing then, and once the sound
    /// has passed the audio plays on from the moved package, started once,
    /// with no play sound. Before, only the announcement's speaking held the
    /// audio, so the move's end in this moment restarted it under the end
    /// sound.
    func testAMoveEndingWhileWhereAmIsEndSoundPlaysHoldsTheAudioUntilTheSoundPasses() throws {
        let playing = try openPlayingAudiobook("Reader Refresh Move Ends In End Sound")
        let reader = playing.reader
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        let generationBefore = reader.chapterPlaybackGeneration

        _ = try moveToShelf(playing) {
            // The announcement ends by itself while the package still moves,
            // so the move ends in the moment its end sound plays.
            reader.whereAmI()
            reader.whereAmIAnnouncementFinished()
        }

        XCTAssertFalse(reader.isWhereAmISpeaking, "The announcement did not end")
        XCTAssertTrue(endSound.hasWorkWaiting, "The end sound's work was not scheduled")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The move's end started the audio over the end sound")
        XCTAssertTrue(reader.isChapterHeldByWhereAmI, "The move's end did not hold the audio for the end sound")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader does not show Playing")
        XCTAssertFalse(reader.isCurrentlyPaused, "The reader shows paused")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore, "The chapter began before the end sound passed")

        endSound.passEndSound()

        try assertPlaysOnFromTheMovedPackage(playing, "As the end sound passed")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 1, "The chapter did not start exactly once")
        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        XCTAssertEqual(playing.sounds.played, [.whereAmIStart, .whereAmIEnd], "A sound beside Where Am I's was made")
        reader.stop()
    }

    /// The end sound's window is a state of its own
    /// (`isWhereAmIEndSoundPlaying`): closed before an announcement, open as
    /// one that ended by itself sounds its end, closed again when the
    /// sound's work runs, and never opened by an announcement the system
    /// cancels, which plays no end sound.
    func testTheEndSoundWindowOpensWhenAnAnnouncementEndsAndClosesWhenItsSoundHasPlayed() throws {
        let playing = try openPlayingAudiobook("Reader Refresh End Sound Window")
        let reader = playing.reader
        var announcements: [AVSpeechUtterance] = []
        reader._whereAmIUtteranceRecorderForTesting = { announcements.append($0) }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        XCTAssertFalse(reader.isWhereAmIEndSoundPlaying, "The window is open before any announcement")
        XCTAssertFalse(reader.isWhereAmISpeakingOrSoundingItsEnd)

        reader.whereAmI()
        XCTAssertFalse(reader.isWhereAmIEndSoundPlaying, "The window is open while the announcement speaks")
        XCTAssertTrue(reader.isWhereAmISpeakingOrSoundingItsEnd, "The announcement speaks")
        reader.whereAmIAnnouncementFinished()

        XCTAssertTrue(reader.isWhereAmIEndSoundPlaying, "The window is not open as the announcement ends")
        XCTAssertTrue(reader.isWhereAmISpeakingOrSoundingItsEnd, "The end sound plays")
        endSound.passEndSound()
        XCTAssertFalse(reader.isWhereAmIEndSoundPlaying, "The window is open after the end sound")
        XCTAssertFalse(reader.isWhereAmISpeakingOrSoundingItsEnd)

        // An announcement the system cancels plays no end sound.
        reader.whereAmI()
        let cancelled = try XCTUnwrap(announcements.last, "No announcement was handed over")
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didCancel: cancelled)
        XCTAssertTrue(waitUntil(timeout: 5) { !reader.isWhereAmISpeaking }, "The cancel did not end the announcement")
        XCTAssertFalse(reader.isWhereAmIEndSoundPlaying, "A cancelled announcement opened the window")
        XCTAssertFalse(endSound.hasWorkWaiting, "A cancelled announcement scheduled end-sound work")
        reader.stop()
    }

    /// What stops the audiobook playing, done while the library moves its
    /// package, takes the audio set aside for the move, so the move's end
    /// leaves the book as it was left: a pause, Play/Pause, a minutes sleep
    /// timer running out, and a recording starting leave it paused, shown
    /// paused; a stop and Release Media Controls leave it stopped. Nothing
    /// is loaded from the package while it moves, nothing plays once the
    /// move is over, and the system no longer shows the book playing; a
    /// pause makes the pause sound, as it would for audio playing. Play
    /// then plays on from the same place in the moved package. Before, each
    /// left the audio set aside, and the move's end played on what had been
    /// stopped; Play/Pause even played the chapter from the moving files
    /// (open after the where-am-i-followups merge).
    func testWhatStopsTheAudioDuringAMoveKeepsItStoppedAfterTheMove() throws {
        preserveSleepTimers()
        for way in StopDuringMove.allCases {
            let context = "\(way.name) during the move"
            let playing = try openPlayingAudiobook("Reader Refresh Stopped During Move \(way)")
            let reader = playing.reader
            let nowPlaying = playing.nowPlaying
            if way == .sleepTimerRunningOut {
                playing.world.settings.sleepFadeOutDuration = 0
                reader.startSleepTimer(duration: .minutes(15))
            }

            var observed: PlayerObservation?
            try recordingAnnouncements {
                observed = try moveToShelf(playing) { way.stop(reader, joining: nowPlaying) }
            }

            let duringMove = try XCTUnwrap(observed, context)
            XCTAssertNil(duringMove.loadedURL, "\(context): the chapter was loaded from the moving package")
            XCTAssertNil(reader.audioPausedForMove, "\(context): the audio is still set aside")
            XCTAssertNil(reader.audioPlaybackService.loadedURL, "\(context): the move's end played the audio on")
            XCTAssertFalse(reader.audioPlaybackService.isPlaying, "\(context): the audio plays")
            XCTAssertEqual(reader.isCurrentlyPlaying, way.leavesTheBookPaused, "\(context): the reader shows the book otherwise")
            XCTAssertEqual(reader.isCurrentlyPaused, way.leavesTheBookPaused, "\(context): the reader shows the book otherwise")
            XCTAssertNil(nowPlaying.playingOwnerID, "\(context): the system still shows the book playing")
            XCTAssertEqual(playing.sounds.played, way.makesThePauseSound ? [.pause] : [], context)

            reader.togglePlayPause()

            try assertPlaysOnFromTheMovedPackage(playing, "\(context), then Play/Pause")
            reader.stop()
        }
    }

    /// Play/Pause while Where Am I? speaks, both pressed while the library
    /// moves the package of the audiobook playing, ends the announcement and
    /// pauses the audio set aside for the move, as it pauses any play
    /// waiting to start, in silence, as it pauses the book an announcement
    /// paused: the move's end leaves the book paused, and Play/Pause then
    /// plays it on from the moved package. Before, the press ended only the
    /// announcement, and the move's end played the audio on.
    func testPlayPauseDuringWhereAmIDuringAMovePausesTheAudioSetAside() throws {
        let playing = try openPlayingAudiobook("Reader Refresh Where Am I Play Pause During Move")
        let reader = playing.reader
        reader._whereAmIUtteranceRecorderForTesting = { _ in }

        _ = try moveToShelf(playing) {
            reader.whereAmI()
            reader.togglePlayPause()
        }

        XCTAssertFalse(reader.isWhereAmISpeaking, "Play/Pause did not end the announcement")
        XCTAssertNil(reader.audioPausedForMove, "The audio is still set aside")
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The move's end played the audio on")
        XCTAssertTrue(reader.isCurrentlyPlaying, "The reader shows the book stopped")
        XCTAssertTrue(reader.isCurrentlyPaused, "The reader does not show the book paused")
        XCTAssertEqual(playing.sounds.played, [.whereAmIStart])

        reader.togglePlayPause()

        try assertPlaysOnFromTheMovedPackage(playing, "Play/Pause after the move")
        reader.stop()
    }

    /// The library moves the package of an audiobook Where Am I? paused as
    /// it played: the paused audio reads nothing and is left alone, marked
    /// to be played afresh, and once the announcement's end sound has
    /// played, the book plays on from the same place in the moved package,
    /// with no play sound, rather than from the player that held the file
    /// where it was. Before, the announcement's resume took up the old
    /// player, ignoring the mark (REV13's leftovers).
    func testAnAudiobookWhoseFilesMoveDuringWhereAmIPlaysOnFromTheMovedPackage() throws {
        let playing = try openPlayingAudiobook("Reader Refresh Moved During Where Am I")
        let reader = playing.reader
        var announcements: [AVSpeechUtterance] = []
        reader._whereAmIUtteranceRecorderForTesting = { announcements.append($0) }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        reader.whereAmI()
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "Where Am I? did not pause the book")

        _ = try moveToShelf(playing) {}

        XCTAssertTrue(reader.audioPlaybackService.isPaused, "The move started or stopped the paused audio")
        XCTAssertTrue(reader.restartPlaybackBackendOnNextResume, "The move did not mark the paused audio to be played afresh")
        let announcement = try XCTUnwrap(announcements.last, "No announcement was handed over")
        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        XCTAssertTrue(waitUntil(timeout: 5) { !reader.isWhereAmISpeaking }, "The announcement did not end")

        endSound.passEndSound()

        XCTAssertFalse(reader.restartPlaybackBackendOnNextResume, "The mark was left for the next resume")
        try assertPlaysOnFromTheMovedPackage(playing, "As Where Am I? ended")
        XCTAssertEqual(playing.sounds.played, [.whereAmIStart, .whereAmIEnd])
        reader.stop()
    }

    // MARK: - Applying Updates

    /// Two readers have the same book open when the library renames it:
    /// each applies the update once, at the book's next revision, and a
    /// reader of another book hears nothing. An update delivered again, or
    /// another book's, changes nothing.
    func testEveryOpenReaderOfTheBookAppliesEachUpdateOnce() throws {
        let world = try makeIntegrationWorld("Reader Refresh Two Readers")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let other = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let readers = [world.openReader(for: book), world.openReader(for: book)]
        let otherReader = world.openReader(for: other)
        for reader in readers + [otherReader] {
            waitForReaderToLoad(reader)
        }
        // Loading can publish a revision of its own: a reader that indexes
        // its book commits the analysis, which every reader takes.
        let revisionBefore = world.library.bookUpdates.revision(of: book.id)
        let otherRevisionBefore = otherReader.appliedLibraryRevision
        let original = try row(of: book, in: world.library)

        world.library.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: original.title], saved: [.title: Self.revisedTitle]),
            of: book.id
        )

        XCTAssertEqual(world.library.bookUpdates.revision(of: book.id), revisionBefore + 1)
        for reader in readers {
            XCTAssertEqual(reader.book.title, Self.revisedTitle)
            XCTAssertEqual(reader.epubMetadata?.title, Self.revisedTitle)
            XCTAssertEqual(reader.appliedLibraryRevision, revisionBefore + 1)
        }
        XCTAssertEqual(otherReader.book.title, "Breakwater Soundings")
        XCTAssertEqual(otherReader.appliedLibraryRevision, otherRevisionBefore, "Another book's reader applied the rename")

        // The same revision again, carrying the old row, is ignored.
        readers[0].applyLibraryUpdate(LibraryBookUpdate(book: original, revision: revisionBefore + 1))
        XCTAssertEqual(readers[0].book.title, Self.revisedTitle, "A repeated revision was applied")
        // So is another book's update, whatever its revision.
        readers[0].applyLibraryUpdate(LibraryBookUpdate(book: other, revision: revisionBefore + 2))
        XCTAssertEqual(readers[0].book.title, Self.revisedTitle, "Another book's update was applied")
    }

    /// While a text book is being spoken, the library renames it and moves
    /// it to another folder. The reader takes the new title and path without
    /// reloading the book and without stopping, restarting, or moving its
    /// speech: the same text, chapter, cursor, and playback generation.
    ///
    /// Speech is marked as under way without the synthesizer, so nothing is
    /// heard; stopping or restarting it would clear or replace that mark.
    func testSpeechGoesOnThroughAnEditAndAMoveWithoutReloading() throws {
        let world = try makeIntegrationWorld("Reader Refresh Speech")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.navigateTo(chapterIndex: 1, characterOffset: 6)
        var loadingStates: [Bool] = []
        let loading = reader.$isLoading.dropFirst().sink { loadingStates.append($0) }
        defer { loading.cancel() }
        let chapterTexts = reader.content?.chapters.map(\.text)
        let generation = reader.chapterPlaybackGeneration
        reader.speechService.isSpeaking = true

        let original = try row(of: book, in: world.library)
        world.library.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: original.title], saved: [.title: Self.revisedTitle]),
            of: book.id
        )
        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")

        XCTAssertEqual(reader.book.title, Self.revisedTitle)
        XCTAssertEqual(reader.book.filePath, try row(of: book, in: world.library).filePath)
        XCTAssertTrue(reader.speechService.isSpeaking, "Speech was stopped")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generation, "Speech was restarted or moved")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 6)
        XCTAssertEqual(reader.content?.chapters.map(\.text), chapterTexts)
        XCTAssertEqual(loadingStates, [], "The book was loaded again")
        reader.speechService.isSpeaking = false
    }

    /// The library renames a book in the moment between a reader opening it
    /// and its content arriving. Once loaded, the reader shows the new title
    /// in its metadata editor too, not the title its load started from.
    func testAnEditMadeWhileTheBookLoadsIsShownOnceItHasLoaded() throws {
        let world = try makeIntegrationWorld("Reader Refresh Loading")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let reader = world.openReader(for: book)

        // The load finishes on the main queue, which runs only once this
        // test waits for it, so the edit always lands while it is under way.
        XCTAssertTrue(reader.isLoading)
        world.library.updateBookMetadata(
            Book.MetadataEdit(
                opened: [.title: book.title, .author: book.author],
                saved: [.title: Self.revisedTitle, .author: Self.revisedAuthor]
            ),
            of: book.id
        )
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertEqual(reader.book.title, Self.revisedTitle)
        XCTAssertEqual(reader.epubMetadata?.title, Self.revisedTitle)
        XCTAssertEqual(reader.epubMetadata?.author, Self.revisedAuthor)
    }

    /// The library moves an audiobook in the moment between a reader
    /// opening it and its content arriving, while the load reads its files
    /// in the background. Whichever finishes first, the reader ends up
    /// loaded, with no error, naming the book's chapter files where they
    /// are now, and plays from there.
    func testABookMovedWhileItLoadsOpensFromWhereItIsNow() throws {
        let world = try makeIntegrationWorld("Reader Refresh Move While Loading")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [2, 2])
        let reader = world.openReader(for: book)

        XCTAssertTrue(reader.isLoading)
        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf") }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "The moved book did not open")
        XCTAssertEqual(reader.content?.chapters.count, 2)
        let stale = staleFields(of: reader, in: world.library, after: "the move while loading")
        XCTAssertTrue(stale.isEmpty, Self.report(stale))
        reader.play()
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: book, in: world.library).filePath)
        )
        reader.stop()
    }

    // MARK: - Loading During a Package Move
    //
    // A reader loads its book off the main thread, reading the book's files
    // where the book was when the load began, and hands what it read back to
    // the main thread. A move made off the main thread
    // (`performLibraryTransition`) can take those files away while they are
    // read, and the read's failure can reach the reader before the library
    // says where the book is now: a full suite on October 20, 2026 saw an
    // audiobook moved as it loaded say "The file “Tracks” in this audiobook
    // is damaged or incomplete" (`testABookMovedWhileItLoadsOpensFromWhereItIsNow`).
    // These tests hold each load on a queue of their own (`HeldLoads`) and
    // let it read at the moment they choose, such as inside the disk's move
    // of `commitLibraryTransition`, which runs on the main thread between the
    // move's two events: once the package has moved, the main run loop
    // turning while the load hands over what it read, as the main thread
    // turns while a move made off it is under way.

    /// A book's folder changes, by Move to Folder… or Rename Folder…, in
    /// the moment its reader's load reads the book's files: the package has
    /// left the place the load reads, and the read's failure reaches the
    /// reader before the library says where the book is now. The reader
    /// takes the failure for the move's doing, not the book's: once the move
    /// is over, it loads the book again from where it is now, and opens it
    /// with no error, naming its files there; an audiobook plays from there.
    /// So for an audiobook of tracks, a text book, and a DAISY audiobook.
    /// Before, the reader said the book could not be read, an audiobook
    /// naming its moved folder as a damaged file ("The file “Tracks” in this
    /// audiobook is damaged or incomplete").
    func testALoadThatReadsAsItsBookMovesOpensTheBookFromWhereItIsNow() throws {
        for kind in LoadedBookKind.allCases {
            for change in FolderChange.allCases {
                let context = "\(kind.name), read as \(change.name) moved it"
                let world = try makeIntegrationWorld("Reader Refresh Read During \(change) \(kind)")
                let book = try makeBook(kind, readyFor: change, in: world)
                let loads = holdLoads()
                let reader = world.openReader(for: book, loadQueue: loads.queue)
                XCTAssertTrue(reader.isLoading, context)

                try commit(change, of: book, in: world) {
                    loads.letReadAndHandOver()
                }

                try assertOpensFromWhereItIsNow(reader, kind, in: world, context)
            }
        }
    }

    /// A book's folder changes, by Move to Folder… or Rename Folder…, after
    /// its reader's load began but before the load reads the book's files:
    /// the whole move is over first, and the reader has been told where the
    /// book is now. The load reads where the book was and finds nothing
    /// there, and the reader loads the book again from where it is now,
    /// opening it with no error. So for an audiobook of tracks, a text book,
    /// and a DAISY audiobook.
    func testALoadThatReadsAfterItsBookMovedOpensTheBookFromWhereItIsNow() throws {
        for kind in LoadedBookKind.allCases {
            for change in FolderChange.allCases {
                let context = "\(kind.name), read after \(change.name) moved it"
                let world = try makeIntegrationWorld("Reader Refresh Read After \(change) \(kind)")
                let book = try makeBook(kind, readyFor: change, in: world)
                let loads = holdLoads()
                let reader = world.openReader(for: book, loadQueue: loads.queue)
                XCTAssertTrue(reader.isLoading, context)

                let made = outcome { await self.runCommand(change, on: book, in: world) }
                XCTAssertTrue(made.succeeded, "\(context): \(made.failureMessage ?? "")")
                loads.letRead()

                try assertOpensFromWhereItIsNow(reader, kind, in: world, context)
            }
        }
    }

    /// A reader opens a book while the library moves its package, as a
    /// book can be opened from the library list in the moment a Move to
    /// Folder… of many books takes. The reader reads nothing of the book
    /// until the move is over, not even where the book was: its storage,
    /// which every load asks first where the library is, hears nothing from
    /// it while the package moves, though its loads are let read. Then it
    /// reads the book once, from where it is now, and opens it with no
    /// error. So for an audiobook of tracks, a text book, and a DAISY
    /// audiobook. Before, its load read the package as it moved and said the
    /// book could not be read.
    func testABookOpenedWhileItsPackageMovesOpensOnceTheMoveIsOver() throws {
        for kind in LoadedBookKind.allCases {
            let context = "\(kind.name), opened as it moved"
            let world = try makeIntegrationWorld("Reader Refresh Opened During Move \(kind)")
            let book = try makeBook(kind, readyFor: .moveToFolder, in: world)
            let loads = holdLoads()
            let storage = ObservedBookStorage()
            let opened = OpenedReader()

            try commit(.moveToFolder, of: book, in: world) {
                opened.reader = world.openReader(
                    for: book,
                    loadQueue: loads.queue,
                    cloud: ReaderCloudServices(storage: storage, states: BookCloudStates())
                )
                loads.letReadAndHandOver()
                opened.readsDuringTheMove = storage.readsBegun
            }

            XCTAssertEqual(opened.readsDuringTheMove, 0, "\(context): the reader read its book as its package moved")
            let reader = try XCTUnwrap(opened.reader, "\(context): no reader opened")
            try assertOpensFromWhereItIsNow(reader, kind, in: world, context)
            XCTAssertEqual(storage.readsBegun, 1, "\(context): the book was not read once the move was over")
        }
    }

    /// A move of a book's package fails once the package has moved, so the
    /// library puts it back where it was. The reader's load read the book in
    /// the moment its package was away, and the read's failure reaches the
    /// reader while the move is under way, or only once the move has been
    /// put back. Either way the reader loads the book again from where it
    /// still is, and opens it with no error. Before, it said the book was
    /// damaged.
    func testALoadThatReadsAsAMoveIsPutBackOpensTheBookWhereItStillIs() throws {
        for failureArrivesDuringTheMove in [true, false] {
            let context = failureArrivesDuringTheMove
                ? "the read's failure taken during the move"
                : "the read's failure taken after the move was put back"
            let world = try makeIntegrationWorld("Reader Refresh Read During Failed Move \(failureArrivesDuringTheMove)")
            let book = try makeBook(.tracks, readyFor: .moveToFolder, in: world)
            let loads = holdLoads()
            let reader = world.openReader(for: book, loadQueue: loads.queue)

            XCTAssertThrowsError(
                try commit(.moveToFolder, of: book, in: world, failing: true, whileMoving: {
                    if failureArrivesDuringTheMove {
                        loads.letReadAndHandOver()
                    } else {
                        loads.letReadBeforeHandingOver()
                    }
                }),
                context
            )

            XCTAssertEqual(try row(of: book, in: world.library).folderPath, world.folder.path, "\(context): the move was kept")
            try assertOpensFromWhereItIsNow(reader, .tracks, in: world, context)
        }
    }

    /// An audiobook whose second track is damaged, and which keeps no index,
    /// so that every load checks its tracks, moves while its reader's load
    /// reads it. The reader loads it again once the move is over, and that
    /// load, from where the book is now, finds the damage: the reader says
    /// the book is damaged, naming the track, exactly as it says when
    /// nothing moves. Before, it named the book's moved folder of tracks as
    /// the damaged file.
    func testADamagedBookMovedAsItLoadsStillSaysWhichFileIsDamaged() throws {
        let world = try makeIntegrationWorld("Reader Refresh Damaged During Move")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1, 1])
        // Damaged once indexed, and the index removed, so loads check the tracks.
        try Data("Not a recording at all.".utf8).write(to: URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav"))
        try FileManager.default.removeItem(at: TextMouthPaths.contentIndexPath(in: book.tmbDirectory))

        // Where nothing moves, the reader names the damaged track.
        let unmoved = world.openReader(for: book)
        waitForReaderToLoad(unmoved)
        let damage = try XCTUnwrap(unmoved.errorMessage, "The damaged book opened")
        XCTAssertTrue(damage.contains("“02.wav”"), "The reader did not name the damaged track: \(damage)")
        unmoved.close()

        let loads = holdLoads()
        let reader = world.openReader(for: book, loadQueue: loads.queue)
        try commit(.moveToFolder, of: book, in: world) {
            loads.letReadAndHandOver()
        }
        waitForReaderToLoad(reader)

        XCTAssertEqual(reader.errorMessage, damage, "The moved book is not said to be damaged as it is")
        XCTAssertNil(reader.content, "The damaged book opened")
    }

    /// A case-only rename of the folder holding a text book, as Rename
    /// Folder… makes it, first waits for an import under way to finish, as
    /// every folder edit waits for the storage work under way, saying so. A
    /// reader that opens the book meanwhile loads it at once: the rename
    /// tells the book's readers that its package will move only once it has
    /// stopped waiting, and the folder keeps its spelling until then. Once
    /// the import finishes, the rename does too, and the reader names the
    /// folder's new spelling. Before, the rename told the readers before it
    /// waited, and a reader stayed on Loading, unannounced, for as long as
    /// the import ran, longer than a finished book's request to play the
    /// next one lasts. (A text book is read without storage work; the load
    /// of an audiobook of tracks looks at its manifest as storage work,
    /// which waits for the rename's own hold on the storage work.)
    func testABookInAFolderBeingRespelledLoadsWhileTheRenameWaitsForAnImport() throws {
        let world = try makeIntegrationWorld("Reader Refresh Respelling Waits")
        let shelf = BookFolder(name: "shelf", parentPath: world.folder.path)
        world.library.library.folders = [BookFolder(name: world.folder.path), shelf]
        let created = try world.importBook(from: writeTideTablesEPUB())
        let move = outcome { await world.library.moveBooksReturningOutcome([created], toFolder: shelf.fullPath) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        let book = try row(of: created, in: world.library)
        // An import holds the storage work, paused as it copies its file.
        let importing = holdFirstImport(of: world.library)
        world.library.importSingleFileAsync(from: try writeImportSource(), toFolder: world.folder.path)
        wait(for: [importing.reached], timeout: 10)
        let announced = VoiceOverAnnouncer.recordedAnnouncements.count

        try FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
            let rename = RenameOutcome()
            Task { @MainActor in
                rename.outcome = await world.library.renameFolderReturningOutcome(shelf, to: "Shelf")
            }
            XCTAssertTrue(
                waitUntil(timeout: 10) {
                    VoiceOverAnnouncer.recordedAnnouncements.dropFirst(announced).map(\.message)
                        .contains(StorageWork.importing.waitingMessage)
                },
                "The rename did not wait for the import"
            )

            let reader = world.openReader(for: book)
            waitForReaderToLoad(reader)
            XCTAssertNil(reader.errorMessage, "The book did not open")
            XCTAssertNotNil(reader.content, "The book did not open")
            XCTAssertNil(rename.outcome, "The rename did not wait for the import")

            importing.gate.signal()
            XCTAssertTrue(waitUntil(timeout: 10) { rename.outcome != nil }, "The rename never finished")
            let renamed = try XCTUnwrap(rename.outcome)
            XCTAssertTrue(renamed.succeeded, renamed.failureMessage ?? "")
            XCTAssertEqual(reader.book.folderPath, "\(world.folder.path)/Shelf", "The reader does not name the new spelling")
            XCTAssertNil(reader.errorMessage)
        }
    }

    /// Play pressed on an audiobook that was not playing, while the library
    /// moves its package, reads no moving files: the chapter waits, the
    /// reader showing Playing, and the move's end plays it from the
    /// package's new place. Before, the play read the moving files and
    /// failed as a damaged book (ST08).
    func testPlayDuringAMoveWaitsForItsEndAndThenPlays() throws {
        let world = try makeIntegrationWorld("Reader Refresh Play During Move")
        let book = try world.makeSilentAudioBook(title: "Tidewrack Chronicle", trackDurations: [2, 2])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")

        world.library.bookUpdates.packagesWillMove([book.id])
        reader.play()
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The play loaded the chapter from the moving package")
        XCTAssertTrue(reader.isPlaybackUnderWay, "The waiting play does not show Playing")

        world.library.bookUpdates.packagesDidMove([book.id])
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: book, in: world.library).filePath),
            "The move's end did not play the chapter from the package"
        )
        reader.stop()
    }

    /// A Pause pressed while a play waits for a move's end lets the play
    /// go: the move's end loads nothing and the reader shows no playback.
    func testAPauseDuringAMoveLetsAWaitingPlayGo() throws {
        let world = try makeIntegrationWorld("Reader Refresh Pause During Move")
        let book = try world.makeSilentAudioBook(title: "Saltmarsh Almanac", trackDurations: [2, 2])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")

        world.library.bookUpdates.packagesWillMove([book.id])
        reader.play()
        XCTAssertTrue(reader.isPlaybackUnderWay, "The waiting play does not show Playing")
        reader.pause()

        world.library.bookUpdates.packagesDidMove([book.id])
        XCTAssertNil(reader.audioPlaybackService.loadedURL, "The move's end played a play the listener paused")
        XCTAssertFalse(reader.isPlaybackUnderWay, "The paused reader still shows Playing")
        reader.stop()
    }

    // MARK: - Stale Fields

    /// Every field of `reader` that no longer matches `library`'s row for
    /// its book, each described as "<step>: <field> is …, the library has
    /// …", or a missing audio file or one outside the book's files.
    private func staleFields(
        of reader: ReaderViewModel,
        in library: LibraryViewModel,
        after step: String
    ) -> [String] {
        guard let row = library.bookByID(reader.book.id) else {
            return ["\(step): the book is no longer in the library"]
        }
        var stale: [String] = []
        /// Notes `field` when the reader's value differs from the library's.
        func compare(_ field: String, _ readerValue: String?, _ libraryValue: String?) {
            guard readerValue != libraryValue else { return }
            stale.append(
                "\(step): \(field) is \(Self.describe(readerValue)), the library has \(Self.describe(libraryValue))"
            )
        }

        compare("book.title", reader.book.title, row.title)
        compare("book.author", reader.book.author, row.author)
        compare("book.folderPath", reader.book.folderPath, row.folderPath)
        compare("book.filePath", Self.displayPath(reader.book.filePath), Self.displayPath(row.filePath))
        compare(
            "book.tmbDirectory",
            Self.displayPath(reader.book.tmbDirectory.path),
            Self.displayPath(row.tmbDirectory.path)
        )
        if let metadata = reader.epubMetadata {
            compare("epubMetadata.title", metadata.title, row.title)
            compare("epubMetadata.author", metadata.author, row.author)
        }
        if let metadata = reader.audioMetadata {
            compare("audioMetadata.title", metadata.title, row.title)
            compare("audioMetadata.artist", metadata.artist, row.author)
        }

        // An audiobook's files are its own path (a folder of tracks, or its
        // one file) or inside it.
        for (number, path) in reader.audioChapterFiles.enumerated() {
            if !FileManager.default.fileExists(atPath: path) {
                stale.append("\(step): audio chapter file \(number + 1) is missing at \(Self.displayPath(path))")
            } else if !Self.isWithin(path, bookPath: row.filePath) {
                stale.append(
                    "\(step): audio chapter file \(number + 1) is \(Self.displayPath(path)), "
                        + "outside the book's files at \(Self.displayPath(row.filePath))"
                )
            }
        }
        if let loaded = reader.audioPlaybackService.loadedURL {
            if !FileManager.default.fileExists(atPath: loaded.path) {
                stale.append("\(step): the player holds \(Self.displayPath(loaded.path)), which no longer exists")
            } else if !Self.isWithin(loaded.path, bookPath: row.filePath) {
                stale.append(
                    "\(step): the player holds \(Self.displayPath(loaded.path)), "
                        + "outside the book's files at \(Self.displayPath(row.filePath))"
                )
            }
        }
        return stale
    }

    /// Whether `path` is the book's own path or inside it.
    private static func isWithin(_ path: String, bookPath: String) -> Bool {
        let file = standardizedPath(path)
        let home = standardizedPath(bookPath)
        return file == home || file.hasPrefix(home + "/")
    }

    /// `path` standardized, so two spellings of one location compare equal.
    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The folder holding the file at `url`, standardized, or nil for none.
    private static func folderPath(of url: URL?) -> String? {
        url.map { standardizedPath($0.deletingLastPathComponent().path) }
    }

    /// `path` with the hosted tests' sandbox home shortened to "~", so
    /// messages stay readable.
    private static func displayPath(_ path: String) -> String {
        let home = HostedTestSandbox.home.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(home) ? "~" + standardized.dropFirst(home.count) : standardized
    }

    /// A value for a stale-field message: quoted text, or "nothing".
    private static func describe(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nothing"
    }

    /// The failure message listing every stale field, one a line.
    private static func report(_ stale: [String]) -> String {
        "The reader kept stale state:\n" + stale.joined(separator: "\n")
    }

    // MARK: - Fixtures

    /// The title and author the Library window's editor gives the book.
    private static let revisedTitle = "Tide Tables, Revised"
    private static let revisedAuthor = "Bronagh Adeyemi"

    /// `book`'s row in `library` now.
    private func row(of book: Book, in library: LibraryViewModel) throws -> Book {
        try XCTUnwrap(library.bookByID(book.id), "\(book.title) is no longer in the library")
    }

    /// `library` with the book `bookID` in the folder `folderPath`, as Move
    /// to Folder… proposes it to the library's transition.
    private static func library(_ library: Library, moving bookID: UUID, to folderPath: String) -> Library {
        var proposed = library
        for index in proposed.books.indices where proposed.books[index].id == bookID {
            proposed.books[index].folderPath = folderPath
        }
        return proposed
    }

    /// A reader playing a two-track silent audiobook, from half a second
    /// into its first track, in a world of its own, and what a test needs
    /// of it.
    @MainActor
    private struct PlayingAudiobook {
        let world: IntegrationWorld
        let book: Book
        let reader: ReaderViewModel
        /// The Now Playing coordinator of the reader's own, through which a
        /// test sends what the system sends.
        let nowPlaying: NowPlayingService
        /// The sound effects the reader asks for once it plays, recorded,
        /// never heard.
        let sounds: RecordedSoundEffects
    }

    /// Opens a reader of a two-track silent audiobook saved half a second
    /// into its first track, in a world of its own named after `label` and
    /// joined to a Now Playing coordinator of its own, and plays it; the
    /// sound effects it asks for from then on are recorded.
    private func openPlayingAudiobook(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlayingAudiobook {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Soundings",
            trackDurations: [2, 2],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 5)
        )
        let nowPlaying = NowPlayingService(installsSystemIntegrations: false)
        let reader = world.openReader(for: book, nowPlaying: nowPlaying)
        waitForReaderToLoad(reader, file: file, line: line)
        XCTAssertNil(reader.errorMessage, "The book did not open", file: file, line: line)
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Playback did not start", file: file, line: line)
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences(label))
        reader.soundEffectService = sounds
        return PlayingAudiobook(world: world, book: book, reader: reader, nowPlaying: nowPlaying, sounds: sounds)
    }

    /// Moves `playing`'s book to the folder Shelf through the library's
    /// transition, as Move to Folder… does, running `whileMoving` as its
    /// package moves, and returns what the player held then, after it ran.
    private func moveToShelf(
        _ playing: PlayingAudiobook,
        file: StaticString = #filePath,
        line: UInt = #line,
        whileMoving: @escaping @MainActor @Sendable () -> Void
    ) throws -> PlayerObservation {
        let world = playing.world
        let duringMove = PlayerObservation()
        try world.library.commitLibraryTransition(
            Self.library(world.library.library, moving: playing.book.id, to: "\(world.folder.path)/Shelf"),
            affectedBookIDs: [playing.book.id],
            disk: observingDisk(playing.reader, into: duringMove, whileMoving: whileMoving)
        )
        XCTAssertEqual(duringMove.moves, 1, "The package did not move once", file: file, line: line)
        return duringMove
    }

    /// The ways a test stops an audiobook's audio while its package moves,
    /// each as the listener or the app stops it.
    private enum StopDuringMove: CaseIterable {
        /// A Pause, as from the AirPods or a media key.
        case pause
        /// Play/Pause, as from the keyboard.
        case playPause
        /// A minutes sleep timer, set before the move, running out.
        case sleepTimerRunningOut
        /// A recording starting, which pauses every book playing.
        case recordingStarting
        /// A stop.
        case stop
        /// Release Media Controls.
        case releaseMediaControls

        /// What a failure message calls it.
        var name: String {
            switch self {
            case .pause: return "a pause"
            case .playPause: return "Play/Pause"
            case .sleepTimerRunningOut: return "the sleep timer running out"
            case .recordingStarting: return "a recording starting"
            case .stop: return "a stop"
            case .releaseMediaControls: return "Release Media Controls"
            }
        }

        /// Whether it leaves the book paused, shown paused, rather than
        /// stopped.
        var leavesTheBookPaused: Bool {
            switch self {
            case .pause, .playPause, .sleepTimerRunningOut, .recordingStarting: return true
            case .stop, .releaseMediaControls: return false
            }
        }

        /// Whether it makes the pause sound: every pause but the sleep
        /// timer's, which pauses in silence.
        var makesThePauseSound: Bool {
            switch self {
            case .pause, .playPause, .recordingStarting: return true
            case .sleepTimerRunningOut, .stop, .releaseMediaControls: return false
            }
        }

        /// Stops `reader`'s audio this way; `nowPlaying` is the coordinator
        /// it joined.
        @MainActor
        func stop(_ reader: ReaderViewModel, joining nowPlaying: NowPlayingService) {
            switch self {
            case .pause:
                reader.pause()
            case .playPause:
                reader.togglePlayPause()
            case .sleepTimerRunningOut:
                reader.sleepTimerService.remainingSeconds = 1
                reader.sleepTimerService._advanceCountdownForTesting()
            case .recordingStarting:
                XCTAssertEqual(nowPlaying.pauseEveryPlayingReader(), 1, "The recording did not pause the book")
            case .stop:
                reader.stop()
            case .releaseMediaControls:
                reader.releaseMediaControls()
            }
        }
    }

    /// Checks that `playing`'s audio plays on, shown playing, from the place
    /// it played at, half a second into the first track, in the package
    /// where the library has moved the book; `context` begins each failure.
    private func assertPlaysOnFromTheMovedPackage(
        _ playing: PlayingAudiobook,
        _ context: String = "After the move",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reader = playing.reader
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "\(context): the audio does not play", file: file, line: line)
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: playing.book, in: playing.world.library).filePath),
            "\(context): the audio does not play from the moved package",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, 0, "\(context): the audio plays another chapter", file: file, line: line)
        XCTAssertEqual(reader.currentCharacterOffset, 5, "\(context): the cursor moved", file: file, line: line)
        XCTAssertEqual(
            reader.audioPlaybackService.currentTime,
            0.5,
            accuracy: 0.001,
            "\(context): the audio plays from another place",
            file: file,
            line: line
        )
        XCTAssertTrue(reader.isCurrentlyPlaying, "\(context): the reader does not show Playing", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPaused, "\(context): the reader shows paused", file: file, line: line)
    }

    /// What a reader's audio player held at the moment a package moved.
    /// Main-actor isolated, as the disk operations of
    /// `commitLibraryTransition` run there.
    @MainActor
    private final class PlayerObservation {
        /// How many packages moved.
        var moves = 0
        /// The file the player held at the last move, if any.
        var loadedURL: URL?
        /// Whether the player was playing at the last move.
        var isPlaying = false
    }

    /// The events the library sent about one book, as the respelling test
    /// records them, and what was on disk and in the player when it heard.
    private final class MoveEventLog {
        var entries: [String] = []
        var listingWhenAnnounced: Set<String> = []
        var playerFileWhenUpdated: URL?
        var subscription: AnyCancellable?
    }

    /// The disk operations a library transition makes, recording into
    /// `observation` what `reader`'s audio player holds as each package
    /// moves. With `failing`, each move throws instead of moving, as a full
    /// disk or a permission problem would, and the transition is put back.
    /// `whileMoving` runs first, as each package moves, as anything can run
    /// on the main thread while a move made off it is under way, so the
    /// player is observed after it.
    private func observingDisk(
        _ reader: ReaderViewModel,
        into observation: PlayerObservation,
        failing: Bool = false,
        whileMoving: @escaping @MainActor @Sendable () -> Void = {}
    ) -> LibraryTransitionDisk {
        LibraryTransitionDisk(
            moveItem: { source, destination in
                // `commitLibraryTransition` runs its disk work on the main
                // actor, where the reader's player lives.
                try MainActor.assumeIsolated {
                    whileMoving()
                    observation.moves += 1
                    observation.loadedURL = reader.audioPlaybackService.loadedURL
                    observation.isPlaying = reader.audioPlaybackService.isPlaying
                    if failing {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            },
            writeRecord: { book in
                try book.saveBookInfoThrowing()
            }
        )
    }

    // MARK: Loading During a Package Move

    /// The kinds of book a reader loads each in its own way: an audiobook of
    /// tracks (its saved index, then its tracks' tags), a text book (its
    /// text cache), and a DAISY audiobook, whose headings play clips of
    /// several files.
    private enum LoadedBookKind: CaseIterable {
        case tracks
        case text
        case daisy

        /// What a failure message calls it.
        var name: String {
            switch self {
            case .tracks: return "an audiobook of tracks"
            case .text: return "a text book"
            case .daisy: return "a DAISY audiobook"
            }
        }

        /// Whether it is an audiobook, which the reader plays from its files.
        var isAudio: Bool {
            self != .text
        }

        /// How many chapters it opens with (`makeBook(_:readyFor:in:)`).
        var chapterCount: Int {
            switch self {
            case .tracks: return 2
            case .text: return 3
            case .daisy: return 2
            }
        }
    }

    /// The changes of a book's folder that move the book's package, each as
    /// its Library window command makes it.
    private enum FolderChange: CaseIterable {
        /// Move to Folder… moves the book into the folder Shelf.
        case moveToFolder
        /// Rename Folder… renames Shelf, the folder holding the book, to
        /// Stacks.
        case renameFolder

        /// What a failure message calls it.
        var name: String {
            switch self {
            case .moveToFolder: return "Move to Folder…"
            case .renameFolder: return "Rename Folder…"
            }
        }
    }

    /// The folder Shelf in `world`'s folder, as books and folders name it.
    private static func shelfPath(in world: IntegrationWorld) -> String {
        "\(world.folder.path)/Shelf"
    }

    /// A book of `kind` in `world`'s folder, listed in the library, with as
    /// many chapters as `kind` says; for Rename Folder…, moved first into
    /// the folder Shelf, which the rename renames. Returns the book's row as
    /// the library then holds it.
    private func makeBook(_ kind: LoadedBookKind, readyFor change: FolderChange, in world: IntegrationWorld) throws -> Book {
        let book: Book
        switch kind {
        case .tracks:
            book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1, 1])
        case .text:
            book = try world.importBook(from: writeTideTablesEPUB())
        case .daisy:
            book = try world.makeSegmentedAudioBook(
                title: "Harbour Soundings",
                files: ["intro.wav": 1, "a.wav": 1, "b.wav": 1],
                sections: [
                    AudioSegment(title: "Opening", file: "intro.wav", startTime: 0, endTime: 1),
                    try XCTUnwrap(AudioSegment(title: "Harbour Survey", clips: [
                        AudioClip(file: "a.wav", startTime: 0, endTime: 1),
                        AudioClip(file: "b.wav", startTime: 0, endTime: 1)
                    ]))
                ]
            )
        }
        guard change == .renameFolder else { return book }
        world.library.library.folders = [
            BookFolder(name: world.folder.path),
            BookFolder(name: "Shelf", parentPath: world.folder.path)
        ]
        let move = outcome { await world.library.moveBooksReturningOutcome([book], toFolder: Self.shelfPath(in: world)) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        return try row(of: book, in: world.library)
    }

    /// The library `change` proposes for `book`, in `world`, as its command
    /// proposes it to the library's transition.
    private func proposedLibrary(_ change: FolderChange, of book: Book, in world: IntegrationWorld) throws -> Library {
        switch change {
        case .moveToFolder:
            return Self.library(world.library.library, moving: book.id, to: Self.shelfPath(in: world))
        case .renameFolder:
            var proposed = world.library.library
            let shelfPath = Self.shelfPath(in: world)
            let shelf = try XCTUnwrap(proposed.folders.first { $0.fullPath == shelfPath }, "There is no folder Shelf")
            try proposed.renameFolderThrowing(id: shelf.id, to: "Stacks")
            return proposed
        }
    }

    /// Makes `change` to `book`'s folder through its Library window command,
    /// whose package moves off the main actor, and returns what happened.
    private func runCommand(_ change: FolderChange, on book: Book, in world: IntegrationWorld) async -> OperationOutcome {
        switch change {
        case .moveToFolder:
            return await world.library.moveBooksReturningOutcome([book], toFolder: Self.shelfPath(in: world))
        case .renameFolder:
            let shelfPath = Self.shelfPath(in: world)
            guard let shelf = world.library.library.folders.first(where: { $0.fullPath == shelfPath }) else {
                return .failure("There is no folder Shelf to rename.")
            }
            return await world.library.renameFolderReturningOutcome(shelf, to: "Stacks")
        }
    }

    /// Makes `change` to `book`'s folder through the library's transition,
    /// as its command proposes it, running `whileMoving` once, after the
    /// book's package has moved on disk and before the library holds its
    /// new row, as anything can run on the main thread then while a move
    /// made off it is under way. With `failing`, the book's record cannot be
    /// written after its package has moved, so the transition is put back,
    /// the package moving back where it was, and the error is thrown.
    private func commit(
        _ change: FolderChange,
        of book: Book,
        in world: IntegrationWorld,
        failing: Bool = false,
        whileMoving: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let proposed = try proposedLibrary(change, of: book, in: world)
        try world.library.commitLibraryTransition(
            proposed,
            affectedBookIDs: world.library.bookIDsChangingFolder(in: proposed),
            disk: .movingPackages(failingRecords: failing, afterFirstMove: whileMoving)
        )
    }

    /// Waits for `reader` to load its book, of `kind`, and checks that it
    /// opened with no error, with all its chapters, naming its files where
    /// `world`'s library has the book now, and that an audiobook plays from
    /// there; `context` begins each failure.
    private func assertOpensFromWhereItIsNow(
        _ reader: ReaderViewModel,
        _ kind: LoadedBookKind,
        in world: IntegrationWorld,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        waitForReaderToLoad(reader, file: file, line: line)
        XCTAssertNil(reader.errorMessage, "\(context): the book did not open", file: file, line: line)
        XCTAssertEqual(reader.content?.chapters.count, kind.chapterCount, "\(context): the chapters", file: file, line: line)
        let stale = staleFields(of: reader, in: world.library, after: context)
        XCTAssertTrue(stale.isEmpty, Self.report(stale), file: file, line: line)
        guard kind.isAudio else { return }
        reader.play()
        XCTAssertEqual(
            Self.folderPath(of: reader.audioPlaybackService.loadedURL),
            Self.standardizedPath(try row(of: reader.book, in: world.library).filePath),
            "\(context): the audio does not play from where the book is now",
            file: file,
            line: line
        )
        reader.stop()
    }

    /// The reader a test opens while a package moves, kept for the test,
    /// with how many reads of its book had begun when the package had moved.
    @MainActor
    private final class OpenedReader {
        var reader: ReaderViewModel?
        var readsDuringTheMove: Int?
    }

    /// An import a test holds as it copies its file (`holdFirstImport(of:)`).
    private struct HeldImport {
        /// Fulfilled once the import is held.
        let reached: XCTestExpectation
        /// Signalled to let the import go on.
        let gate: DispatchSemaphore
    }

    /// The first import `library` runs, held as it copies its file, and so
    /// holding the storage work, until the test signals the returned gate;
    /// later imports pass. The import is let go, and the seam removed, when
    /// the test ends at the latest.
    private func holdFirstImport(of library: LibraryViewModel) -> HeldImport {
        let reached = expectation(description: "the import began to copy its file")
        // Fulfilled once only, which `FirstClaim` sees to as well: a second
        // fulfilment would abort the test host.
        reached.assertForOverFulfill = false
        let held = HeldImport(reached: reached, gate: DispatchSemaphore(value: 0))
        let first = FirstClaim()
        let queue = library.importOperationQueue
        queue.stepObserver = { step, _ in
            guard step == .copying, first.claim() else { return }
            held.reached.fulfill()
            _ = held.gate.wait(timeout: .now() + 60)
        }
        addTeardownBlock {
            queue.stepObserver = nil
            held.gate.signal()
        }
        return held
    }

    /// A short text file to import, in a folder of this test's own.
    private func writeImportSource() throws -> URL {
        let file = try makeSandboxDirectory("ReaderRefreshImport").appendingPathComponent("Slipway Notes.txt")
        try Data("Slipway Notes\n\nThe pilot boards at the fairway buoy.\n".utf8).write(to: file)
        return file
    }

    /// What a folder edit a test started returned, once it has.
    @MainActor
    private final class RenameOutcome {
        var outcome: OperationOutcome?
    }

    /// Whether something has been claimed yet, as an import's step observer
    /// asks from its own thread. `@unchecked Sendable`: its one property is
    /// read and written with `lock` held.
    private final class FirstClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        /// Whether this is the first claim.
        func claim() -> Bool {
            lock.withLock {
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }

    /// A three-chapter EPUB about tides, each chapter listed in its table
    /// of contents, in a folder of this test's own.
    private func writeTideTablesEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("ReaderRefreshSources").appendingPathComponent("tide-tables.epub")
        let chapters = [
            ("Spring Tides", "Twice a month the sun and moon pull in line and the range is widest."),
            ("Neap Tides", "Between them the pulls cross and the water barely climbs the harbour steps."),
            ("Slack Water", "At the turn the current rests for a few minutes before it runs again."),
        ]
        try IntegrationEPUB.write(
            title: "Tide Tables",
            chapters: chapters.enumerated().map { number, chapter in
                IntegrationEPUBChapter(fileName: "ch0\(number + 1).xhtml", body: "<h1>\(chapter.0)</h1><p>\(chapter.1)</p>")
            },
            contents: chapters.enumerated().map { number, chapter in
                IntegrationTOCEntry(label: chapter.0, target: "ch0\(number + 1).xhtml")
            },
            to: epub
        )
        return epub
    }
}
