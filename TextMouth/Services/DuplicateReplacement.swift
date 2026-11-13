import Foundation

// MARK: - Replace Existing Keeps the Old Copy's State (ST04)

/// What Replace Existing does with a duplicate's two copies (ST04; PLAN
/// 0.2.0, 3.2 item 4): the new copy, which its import has already published
/// in a package of its own, takes the place in the library of the copy the
/// library holds, the one the user has been reading, as that same book.
///
/// The new copy keeps the old copy's:
/// - ID, so its place on the reading list, its listening statistics, Keep on
///   This Mac, and every other choice made for the book by its ID stay;
/// - folder, its place in that folder's manual order, its date added, and
///   when it was last opened and played;
/// - reading position, bookmarks with their notes, and skipped headings,
///   moved from the old text to the new one by the words they were saved by
///   (`PlaceRelocator`) where the two texts differ. An audiobook's places
///   count time in its recording (P08): where the two chapter lists differ,
///   they follow their tracks, or their times, to the new chapters
///   (`movedAudioPlaces(_:from:to:at:)`);
/// - own settings (`Book.hasOwnSettings`): voice, speed, pitch, what happens
///   at its end, and the units of its skips;
/// - metadata the user edited by hand (`Book.HandEdits`);
/// - copies Edit Text kept of an edited text, and the old text itself, as
///   one more such copy beside the new text, when it holds text TextMouth
///   did not write: an Edit Text change, or a save no edit took. It is never
///   laid over the new text, which may differ: an edit holds only for the
///   text it was made in (B12);
/// - transcript, when the new copy's audio is the audio transcribed
///   (`TranscriptTextLoader.audioCheck`).
///
/// Everything else is the new copy's: its file and text, what reading them
/// measured, its title and author where the user edited neither, and where
/// it came from. A copy of the other kind (an audiobook for a text book)
/// keeps only the old copy's ID, its place in the library, and its
/// hand-edited metadata: a text book's places and speed mean nothing to an
/// audiobook.
///
/// A BRF or BRL braille copy of the same file is read in the old copy's
/// braille file characters, though, not in the Braille setting's its import
/// read it in, so a choice the user made in Book Information survives the
/// replacement (`brailleFileCodeToReadAgain(replacing:with:)`, braillecodes).
/// So is a text copy in the encoding the user chose for the old copy there,
/// when the choice is about the new file too (`textEncodingToReadAgain(replacing:with:)`,
/// encodingchoice): the same bytes, or other bytes that name no encoding of
/// their own and are valid in the choice. Other bytes the choice cannot read
/// keep their import's reading, and the replacement goes ahead.
///
/// The work is in three parts, so that the old copy's package goes only
/// once the new copy is committed:
/// 1. `prepare(replacing:with:access:now:)` first reads a braille copy
///    again in the old copy's braille file characters, or a text copy in the
///    old copy's chosen encoding, when it must be;
///    then reads what is carried over, refusing before anything more is
///    written when part of it is only in the cloud, and putting back what
///    was read again; then writes it into the new copy's package and moves
///    that package into the old copy's folder. The row it returns has the
///    old copy's ID; the new package's record keeps the import's own until
///    the library commits that row.
/// 2. The library commits the new copy (`LibraryViewModel+Duplicates`): its
///    record, then, once the marker saying it waits for this answer is off
///    (`DuplicateQuestionMarker`), the index naming it, each on disk before
///    the next step. A commit that fails undoes the first part
///    (`Preparation.undo()`), and the question stays, its copy marked again.
/// 3. The library removes the old copy's package
///    (`removeReplacedPackage(of:movesToTrash:)`). Nothing is undone then: a
///    package that cannot be removed stays, its record naming a listed
///    book, which no launch adopts (`FileImportService.adoptOrphanedTMBPackages`).
enum DuplicateReplacement {
    /// What a refusal asks the user to do once its cause is gone.
    static let retry = "choose Replace Existing again"

    // MARK: Refusals

    /// Why Replace Existing waits rather than replace the library's copy: the
    /// copy is in use in a way the replacement would break, or something the
    /// replacement carries over is only in the cloud, where it is never
    /// downloaded for it. Nothing has changed, and the question stays,
    /// saying why and what to do.
    enum Refusal: LocalizedError, Equatable {
        /// The copy is open in a reader, being transcribed, or being
        /// exported: the uses a deletion of a feed's download refuses too
        /// (`FeedBookUse`). A reader would go on saving its places, in the
        /// old text's numbering, into the new copy, which has the same ID.
        case inUse(FeedBookUse, title: String)
        /// The copy's audio is being edited in the audio editor, or saved
        /// from it, which would write the old copy's edits into the new one.
        case audioBeingEdited(title: String)
        /// A file the replacement carries over, or the package that lists
        /// them, is only in the cloud.
        case filesInCloud(title: String)
        /// Another operation holds the library's storage work, as a folder
        /// edit moving its books' packages does: the replacement would move
        /// and remove packages under it (ST04 review, finding 5).
        case storageBusy(StorageHoldReason)
        /// The copy's text is being read again in another encoding
        /// (encodingchoice), which writes into the package the replacement
        /// removes. It carries the re-read's own sentence
        /// (`LibraryViewModel.readingAgainRefusal(of:)`), said as it is.
        case readingAgain(String)
        /// The new copy could not be read in the braille file characters
        /// (braillecodes) or the text encoding (encodingchoice) the copy in
        /// the library is read in, which the listener chose in Book
        /// Information, though its bytes are the old copy's: taken as its
        /// import read it, it would undo that choice. It carries the reading's own sentence
        /// (`readCopyAgain(_:as:access:)`), said as it is.
        case copyNotReadAgain(String)

        /// The refusal as the question's sheet shows it and VoiceOver
        /// speaks it.
        var sentence: String {
            switch self {
            case .readingAgain(let sentence), .copyNotReadAgain(let sentence):
                return sentence
            case .inUse(let use, let title):
                return use.refusal(of: "“\(title)”", doing: "replacing it", retry: DuplicateReplacement.retry)
            case .audioBeingEdited(let title):
                return "The audio of “\(title)” is being edited. Close the audio editor, or wait until it has saved, "
                    + "then \(DuplicateReplacement.retry)."
            case .filesInCloud(let title):
                return "Some of the files of “\(title)” are only in the cloud, and replacing it now would leave them behind. "
                    + "Download the book, then \(DuplicateReplacement.retry)."
            case .storageBusy(.movingBooksBetweenFolders):
                return "TextMouth is moving books between folders. Wait until that finishes, then \(DuplicateReplacement.retry)."
            case .storageBusy(.rebuildingDirectory):
                return "TextMouth is rebuilding its data directory. Wait until that finishes, then \(DuplicateReplacement.retry)."
            case .storageBusy(.movingDataDirectory):
                return DataDirectoryMoveWording.importAnswerRefusal
            case .storageBusy(let reason):
                // Switching libraries ends with TextMouth opening again on
                // the other one: there is no "again" to wait for.
                return StorageBusyError(reason: reason).errorDescription ?? ""
            }
        }

        var errorDescription: String? {
            sentence
        }
    }

    /// Why a replacement could not keep the old copy's text beside the new
    /// copy's: nothing was replaced, and the question stays.
    struct TextNotKept: LocalizedError, Equatable {
        var errorDescription: String? {
            "TextMouth couldn't keep the edited text of the copy in your library beside the new copy's text, "
                + "so it left both copies as they are."
        }
    }

    /// Why a replacement could not be committed: the library's index, which
    /// must name the new copy before the old one goes, could not be saved
    /// now. Nothing was replaced, and the question stays.
    struct IndexNotSaved: LocalizedError, Equatable {
        var errorDescription: String? {
            "TextMouth couldn't save the library's index, so it left both copies as they are."
        }
    }

    // MARK: Removing the Old Copy's Package

    /// Removes the package of `existing`, which a committed new copy has
    /// replaced: to the Trash in one move when `movesToTrash`, under its own
    /// name, so the Trash shows it; otherwise renamed first, in one step, to
    /// a staged package's hidden name in its own folder
    /// (`ImportStaging.freshName()`), then deleted with everything in it
    /// (`ImportStaging.removeStagedPackage(at:)`, which gives back write
    /// permission a read-only item inside took away, as an RTFD's folder can
    /// keep). The rename comes first because a deletion can stop partway,
    /// and a half-deleted package left under its own name would be a broken
    /// book in the library; under a staged name nothing in TextMouth treats
    /// it as a book or a folder, and the next import into that folder
    /// removes what is left (`ImportStaging.removeAbandoned(in:)`). This is
    /// simpler than an undo, which could only take back what the new copy
    /// was given. A package already gone counts as removed.
    /// - Throws: the deletion guard's refusal
    ///   (`FileImportService.managedPackageURLForDeletion`), or why the
    ///   package could not be moved to the Trash or set aside: it is then
    ///   whole, in its folder.
    @MainActor
    static func removeReplacedPackage(of existing: Book, movesToTrash: Bool) throws {
        let package = try FileImportService.managedPackageURLForDeletion(existing)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: package.path) else { return }
        if movesToTrash {
            // Never a permanent deletion in its place: a Trash failure stays
            // a failure.
            try fileManager.trashItem(at: package, resultingItemURL: nil)
            return
        }
        let aside = package.deletingLastPathComponent().appendingPathComponent(ImportStaging.freshName(), isDirectory: true)
        try fileManager.moveItem(at: package, to: aside)
        // What cannot be deleted is logged (IMPORT_STAGING_LEFT) and left
        // for the next import into the folder.
        ImportStaging.removeStagedPackage(at: aside)
    }

    /// What VoiceOver hears once the new copy took the place of the book
    /// titled `title` and the old copy's text was kept beside the new text
    /// as `copy`, naming the copy as Edit Text names the copies it keeps
    /// (`BookTextEditWording.earlierTextKept(_:)`, which a re-read in another
    /// encoding says too), so the user knows where the earlier text is.
    static func keptTextAnnouncement(title: String, copy: URL) -> String {
        "Replaced “\(title)”. \(BookTextEditWording.earlierTextKept(copy))"
    }

    /// What the library's alert says when the package of the copy titled
    /// `title` could not be removed for `reason` after the new copy took its
    /// place, which stands: moved to the Trash, or deleted, as
    /// `movesToTrash` says, and the old files stay in their folder.
    static func oldCopyLeftMessage(title: String, movesToTrash: Bool, reason: String) -> String {
        let removal = movesToTrash ? "moved to the Trash" : "deleted"
        return "The new copy took the place of “\(title)”, but the old copy's files could not be \(removal), "
            + "so they stay in its folder: \(reason)"
    }

    // MARK: The Row

    /// The row the new copy `copy` becomes in the library in place of
    /// `existing`: the new copy's file, text, and analysis at `location`,
    /// under `existing`'s ID, with `existing`'s place in the library, its
    /// hand-edited metadata, and, for a copy of the same kind, its playback
    /// times, its own settings, and `places`, its places as the new copy
    /// keeps them (`carriedPlaces`). Pure.
    static func carriedBook(
        replacing existing: Book,
        with copy: Book,
        places: PlaceRelocator.Places,
        location: Book.FileLocation
    ) -> Book {
        var carried = copy.withID(existing.id)
        carried.fileLocation = location
        // Where the book is in the library, which the user arranged.
        carried.manualSortOrder = existing.manualSortOrder
        carried.dateAdded = existing.dateAdded
        carried.lastOpened = existing.lastOpened
        carried.keepHandEditedMetadata(of: existing)
        // A text book's places and speed mean nothing to an audiobook, and
        // an audiobook's mean nothing to a text book.
        guard areSameKind(existing, copy) else { return carried }
        carried.lastPlaybackStarted = existing.lastPlaybackStarted
        carried.lastPlaybackStopped = existing.lastPlaybackStopped
        carried.takeOwnSettings(of: existing)
        carried.readingPosition = places.position
        carried.bookmarks = places.bookmarks
        carried.setSkippedHeadings(places.skippedHeadings)
        carried.waitingSkippedHeadings = SkippedHeading.stored(places.waitingSkippedHeadings)
        return carried
    }

    /// Whether `first` and `second` are both audiobooks or both text books,
    /// whose places, speed, and transcript mean the same in either.
    static func areSameKind(_ first: Book, _ second: Book) -> Bool {
        first.format.isAudio == second.format.isAudio
    }

    /// Where `copy`'s file is once its package, published by its import, is
    /// at `package` in the library folder `folderPath`: at the same path
    /// inside the package. A file outside its package, which no import
    /// makes, is taken to be at the top of it.
    static func location(of copy: Book, movedTo package: URL, folderPath: String) -> Book.FileLocation {
        let published = copy.tmbDirectory.standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: copy.filePath).standardizedFileURL.path
        let inside = file.hasPrefix(published)
            ? String(file.dropFirst(published.count))
            : URL(fileURLWithPath: copy.filePath).lastPathComponent
        return Book.FileLocation(
            folderPath: folderPath,
            filePath: package.appendingPathComponent(inside).path,
            tmbDirectoryName: copy.tmbDirectoryName
        )
    }

    // MARK: The Places

    /// `existing`'s places as the new copy `copy` keeps them: for two text
    /// books, moved from the old copy's text to the new copy's by the words
    /// they were saved by (`PlaceRelocator.relocate(_:from:to:movedAt:)`),
    /// which parses the old text only when some place does not stand in the
    /// new one; for two audiobooks, moved by time; otherwise, as they are.
    /// Nothing is said or shown; when any text place moved, the debug log
    /// gets the relocator's counts (PLACES_RELOCATED).
    ///
    /// - A text book's places nothing could move (none saved, or a reading
    ///   position at the very start) stay, and neither text is read.
    /// - With no new text to read (`newText` gives nil), the places stay,
    ///   and the reader finds them by their words when it first loads the
    ///   new copy.
    /// - With no old text to read (`oldText` throws: it is gone, or only in
    ///   the cloud), the places are found in the new text by their words
    ///   alone, as a reader's load finds them
    ///   (`PlaceRelocator.relocate(_:within:movedAt:)`), and a place nothing
    ///   finds stays as it was saved.
    /// - An audiobook's places count time in its recording (P08): they move
    ///   to the new copy's chapters when its chapter list differs from the
    ///   old copy's (`movedAudioPlaces(_:from:to:at:)`), read from the two
    ///   copies' indexes (`oldIndex`, `newIndex`), and stay as they were
    ///   saved when either index cannot be read.
    static func carriedPlaces(
        of existing: Book,
        copy: Book,
        oldText: () throws -> DocumentContent,
        newText: () -> DocumentContent?,
        oldIndex: () -> BookContentIndex? = { nil },
        newIndex: () -> BookContentIndex? = { nil },
        movedAt date: Date
    ) -> PlaceRelocator.Places {
        let saved = existing.relocatablePlaces
        guard areSameKind(existing, copy) else { return saved }
        if copy.format.isAudio {
            guard let old = oldIndex(), let new = newIndex() else { return saved }
            return movedAudioPlaces(saved, from: old, to: new, at: date)
        }
        guard existing.holdsPlacesToMove, let newText = newText() else {
            return saved
        }
        let outcome: PlaceRelocator.Outcome?
        do {
            outcome = try PlaceRelocator.relocate(saved, from: oldText, to: newText, movedAt: date)
        } catch {
            outcome = PlaceRelocator.relocate(saved, within: newText, movedAt: date)
        }
        guard let outcome else { return saved }
        if outcome.counts.anythingMoved {
            DiagnosticLog.event(.storage, outcome.counts.logLine(title: existing.title))
        }
        return outcome.places
    }

    /// An audiobook's `places`, saved on the old copy's chapters (`old`, its
    /// index), moved to the new copy's (`new`), as of `date` (ST04 review,
    /// finding 2). An audiobook's place is a chapter and the time into it,
    /// and the reader holds an offset past its chapter's end at that end, so
    /// a place kept as it was on another chapter list would land wrong: a
    /// position three hours into a book read as one chapter, opened on the
    /// same recording read with its chapter marks, would be the end of the
    /// first chapter.
    ///
    /// - The same chapter list: the places stay.
    /// - Books of tracks, one track to a chapter, every old track among the
    ///   new copy's: each place follows its track, at the same time into it
    ///   (`TrackPlaces`), whatever order either copy plays them in, as after
    ///   an edit of the old copy's manifest (FR17), which is not carried.
    /// - Otherwise each place goes through time on the recording: where its
    ///   old chapter starts plus its offset's time, never held to that
    ///   chapter's end, then the new chapter that holds that time
    ///   (`PlaceClock.place(atTime:)`); the end of the old recording is the
    ///   end of the new one. Skipped headings name headings by their place,
    ///   which another chapter list does not keep, so they wait, naming no
    ///   heading, rather than skip whatever section came to have their ID.
    static func movedAudioPlaces(
        _ places: PlaceRelocator.Places,
        from old: BookContentIndex,
        to new: BookContentIndex,
        at date: Date
    ) -> PlaceRelocator.Places {
        guard chapterLayout(of: old) != chapterLayout(of: new) else { return places }
        let oldTracks = old.chapters.compactMap(\.audioFilePath)
        if playsOneTrackPerChapter(old), playsOneTrackPerChapter(new),
           Set(oldTracks).isSubset(of: Set(new.chapters.compactMap(\.audioFilePath))) {
            return TrackPlaces.moved(places, from: old, to: new, at: date)
        }
        let oldClock = PlaceClock.recording(of: old)
        let newClock = PlaceClock.recording(of: new)
        /// The place on the new chapters at the time `chapter` and `offset`
        /// stood for on the old recording.
        func movedPlace(chapter: Int, offset: Int) -> PlaceClock.Place {
            newClock.place(atTime: time(on: oldClock, chapter: chapter, offset: offset))
        }

        var moved = places
        if var position = places.position {
            let place = movedPlace(chapter: position.chapterIndex, offset: position.characterOffset)
            if place.chapterIndex != position.chapterIndex || place.characterOffset != position.characterOffset {
                position.chapterIndex = place.chapterIndex
                position.characterOffset = place.characterOffset
                position.lastUpdated = date
                if position.globalCharacterOffset != nil {
                    position.globalCharacterOffset = new.chapterStartOffset(place.chapterIndex) + place.characterOffset
                }
            }
            moved.position = position
        }
        moved.bookmarks = places.bookmarks.map { bookmark in
            let place = movedPlace(chapter: bookmark.chapterIndex, offset: bookmark.characterOffset)
            var copy = bookmark
            copy.chapterIndex = place.chapterIndex
            copy.characterOffset = place.characterOffset
            return copy
        }
        moved.waitingSkippedHeadings = places.waitingSkippedHeadings + places.skippedHeadings
        moved.skippedHeadings = []
        return moved
    }

    /// The time on `clock` of `chapter` and `offset`: where the chapter
    /// starts plus the time the offset stands for, not held to the chapter's
    /// end, as `PlaceClock.time(chapterIndex:characterOffset:)` holds it. A
    /// chapter before the first is the beginning, and one after the last the
    /// end.
    private static func time(on clock: PlaceClock, chapter: Int, offset: Int) -> TimeInterval {
        guard let last = clock.chapterStarts.indices.last, chapter >= 0 else { return 0 }
        guard chapter <= last else { return clock.length }
        guard clock.unitsPerSecond > 0 else { return clock.chapterStarts[chapter] }
        return clock.chapterStarts[chapter] + Double(max(0, offset)) / clock.unitsPerSecond
    }

    /// One chapter of an audiobook's index as places depend on it: its
    /// file, where it starts in that file, how long it lasts, and its
    /// length in the reader's units.
    private struct ChapterLayout: Equatable {
        let file: String?
        let start: TimeInterval?
        let duration: TimeInterval?
        let length: Int
    }

    /// Each chapter of `index` as places depend on it.
    private static func chapterLayout(of index: BookContentIndex) -> [ChapterLayout] {
        index.chapters.map {
            ChapterLayout(file: $0.audioFilePath, start: $0.audio?.startTime, duration: $0.audio?.duration, length: $0.characterCount)
        }
    }

    /// Whether every chapter of `index` plays a whole file of its own, as a
    /// book of tracks does, so a place can follow its track by the file.
    private static func playsOneTrackPerChapter(_ index: BookContentIndex) -> Bool {
        let tracks = index.chapters.compactMap(\.audioFilePath)
        return !index.chapters.isEmpty
            && tracks.count == index.chapters.count
            && Set(tracks).count == tracks.count
            && index.chapters.allSatisfy { $0.audio?.clips == nil && ($0.audio?.startTime ?? 0) == 0 }
    }

    // MARK: Preparing the New Copy's Package

    /// The new copy's package, made ready to take the old copy's place, and
    /// what the library needs to finish the replacement or undo it. Made off
    /// the main actor and handed back to it
    /// (`LibraryViewModel.answerImportDecisionOffMain(_:with:prepare:)`).
    struct Preparation: Sendable {
        /// The library row the new copy becomes (`carriedBook`), at its
        /// package's new place.
        let book: Book
        /// Whether the old copy's transcript went into the new package.
        let keptTranscript: Bool
        /// Whether the new package holds a transcript, the old copy's or the
        /// one the new copy brought from a file beside its audio (FMT23): what
        /// the library row and the offer to transcribe follow.
        let hasTranscript: Bool
        /// The transcript the new copy brought from a file beside its audio
        /// that the old copy's took the place of (`TranscriptOutcome`), so the
        /// listener can be told it was not used; nil when it brought none, or
        /// it stayed.
        let broughtTranscriptNotUsed: BroughtTranscript?
        /// The copy of the old copy's text kept now beside the new text, when
        /// one was made.
        let keptText: URL?
        /// Where the import published the new package.
        let publishedAt: URL
        /// Where the new package is now: in the old copy's folder.
        let movedTo: URL
        /// The names at the top of the new package before anything was
        /// carried into it.
        let namesBefore: Set<String>
        /// The new copy read again in the old copy's braille file
        /// characters, with its files as its import wrote them; nil when it
        /// was not read again.
        fileprivate let copyReadAgain: CopyReadAgain?

        /// Puts the new package back as its import published it, as a
        /// replacement that could not be committed must leave it: moved back
        /// to where it was published, without anything carried into it, and
        /// with the text and record its import wrote, when it was read again
        /// in the old copy's braille file characters. Never called once the
        /// new copy is committed. What cannot be put back is logged; the
        /// question stays either way.
        func undo() {
            DuplicateReplacement.undo(publishedAt: publishedAt, movedTo: movedTo, namesBefore: namesBefore)
            // Once the package is back where its files were kept.
            copyReadAgain?.putBack()
        }
    }

    /// What a replacement carries over from the old copy's package, read in
    /// full before anything is written.
    private struct Carried {
        /// The names of the copies Edit Text kept in the old package.
        var keptCopyNames: [String] = []
        /// The old copy's text, to keep beside the new copy's, when it holds
        /// text TextMouth did not write.
        var unwrittenText: Data?
        /// transcript.json as the new package takes it, when the new copy's
        /// audio is the audio transcribed.
        var transcript: Data?
        /// The transcript kept before its cleanup, as the new package takes
        /// it, with the transcript.
        var transcriptBeforeCleanup: Data?
        /// The transcript the new copy brought from a file beside its audio,
        /// when the old copy's is carried over it.
        var broughtTranscriptNotUsed: BroughtTranscript?
        /// The old copy's places as the new copy keeps them.
        var places = PlaceRelocator.Places()
    }

    /// Makes the new copy `copy`'s package ready to take the place of
    /// `existing`, the library's copy, and returns the row it becomes.
    ///
    /// A BRF or BRL braille copy of the same file is first read again in the
    /// braille file characters `existing` is read in, when its own are other
    /// ones and its bytes did not say which they are
    /// (`brailleFileCodeToReadAgain(replacing:with:)`, braillecodes). Its
    /// import read it in the Braille setting's characters, so a choice the
    /// user made in Book Information, such as Eurobraille for a book first
    /// read as North American Braille ASCII, would otherwise be undone with
    /// no error, the book read with wrong digits, punctuation, and
    /// contractions. A text copy is read again in the encoding the user
    /// chose for `existing` when the choice is about its file too
    /// (`textEncodingToReadAgain(replacing:with:)`, encodingchoice), as a
    /// Cyrillic file chosen as Windows-1251 would otherwise be read as the
    /// import guessed. Either is read as Book Information reads a book again
    /// (`readCopyAgain(_:as:access:)`): its text written anew, and its
    /// package record taking the choice, with the new text's analysis, so its
    /// row and record agree, and the places below move onto that text. A
    /// copy that cannot be read so is refused, never taken as its import
    /// read it.
    ///
    /// Everything carried over is read next, without downloading anything
    /// (`access`): the copies Edit Text kept, the old text when it holds text
    /// TextMouth did not write, the transcript when the new copy's audio is
    /// the audio transcribed, and both texts, for the places. Only then is
    /// anything more written: those files go into the new package, which
    /// then moves into `existing`'s folder. A failure while writing undoes
    /// what was written before it throws, and any failure once the copy was
    /// read again puts its text and record back as its import wrote them.
    ///
    /// - Throws: the deletion's own error for a row naming no package the
    ///   library manages (`FileImportService.managedPackageURLForDeletion`);
    ///   `Refusal.copyNotReadAgain` when a copy could not be read in
    ///   `existing`'s braille file characters or chosen encoding; `Refusal.filesInCloud` when
    ///   something carried over is only in the cloud, before anything is
    ///   carried in; `TextNotKept` when the old text could not be kept beside
    ///   the new one; or the file system's error. The new package is then as
    ///   its import published it.
    static func prepare(
        replacing existing: Book,
        with copy: Book,
        access: MaintenanceFileAccess = .live,
        now: Date = Date()
    ) throws -> Preparation {
        // The rule the old package's deletion follows, before anything is
        // read or written: a row naming no package the library manages (no
        // package name, or one outside the library) has nothing of its own
        // to carry over, and its package could not be deleted after.
        _ = try FileImportService.managedPackageURLForDeletion(existing)
        let publishedAt = copy.tmbDirectory
        // The copy in the old copy's braille file characters or text
        // encoding, before its text is read for the places; from here on,
        // the copy is this one.
        let readAgain = try readingToCarry(replacing: existing, with: copy).map {
            try readCopyAgain(copy, as: $0, access: access)
        }
        let newCopy = readAgain?.copy ?? copy
        // Whatever fails from here puts the copy's files back as its import
        // wrote them, after the catch below has undone what was carried in.
        var isPrepared = false
        defer {
            if !isPrepared { readAgain?.putBack() }
        }
        let carried = try readCarried(from: existing, for: newCopy, access: access, now: now)
        // What the import published, listed before anything is carried in,
        // which an undo leaves: a package that cannot be listed fails here,
        // with nothing written, rather than give an undo nothing to keep.
        let namesBefore = Set(try FeedItemPackage.listedEntryNames(of: publishedAt))
        let destination = TextMouthPaths.tmbPath(folderPath: existing.folderPath, tmbName: newCopy.tmbDirectoryName)
        var movedTo = publishedAt
        var keptText: URL?
        do {
            keptText = try write(carried, from: existing.tmbDirectory, into: publishedAt)
            if destination.standardizedFileURL.path != publishedAt.standardizedFileURL.path {
                try TextMouthPaths.ensureLibrarySubfolder(existing.folderPath)
                try FileManager.default.moveItem(at: publishedAt, to: destination)
                movedTo = destination
                // The copy moved with its package.
                keptText = keptText.map { movedTo.appendingPathComponent($0.lastPathComponent) }
            }
        } catch {
            undo(publishedAt: publishedAt, movedTo: movedTo, namesBefore: namesBefore)
            throw error
        }
        let book = carriedBook(
            replacing: existing,
            with: newCopy,
            places: carried.places,
            location: location(of: newCopy, movedTo: movedTo, folderPath: existing.folderPath)
        )
        // Nothing fails from here: what was read again is the preparation's
        // to put back, should the library not commit it.
        isPrepared = true
        return Preparation(
            book: book,
            keptTranscript: carried.transcript != nil,
            // The package as it is now: the transcript carried over, or the
            // one the new copy brought (S1).
            hasTranscript: carried.transcript != nil
                || FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: movedTo).path),
            broughtTranscriptNotUsed: carried.broughtTranscriptNotUsed,
            keptText: keptText,
            publishedAt: publishedAt,
            movedTo: movedTo,
            namesBefore: namesBefore,
            copyReadAgain: readAgain
        )
    }

    /// Reads what the replacement of `existing` by `copy` carries over from
    /// the old package, without downloading anything and without writing.
    /// - Throws: `Refusal.filesInCloud` when the old package, or a file
    ///   carried over, is only in the cloud.
    private static func readCarried(
        from existing: Book,
        for copy: Book,
        access: MaintenanceFileAccess,
        now: Date
    ) throws -> Carried {
        let old = OldPackage(book: existing, access: access)
        try old.requireOnThisMac(old.package)
        let names = try old.read(old.package) { try FeedItemPackage.listedEntryNames(of: old.package) }
        var carried = Carried()

        // The copies Edit Text kept, which may be the only copy of an edit.
        carried.keptCopyNames = names.filter(TextMouthPaths.isKeptTextCopy).sorted()
        for name in carried.keptCopyNames {
            try old.requireOnThisMac(old.package.appendingPathComponent(name))
        }

        // The old text, read once: for the places, and to keep when it holds
        // text TextMouth did not write. One only in the cloud is read only
        // when it must be kept.
        let oldTextURL = TextMouthPaths.contentMarkdownPath(in: old.package)
        let holdsOldText = names.contains(TextMouthPaths.contentMarkdownFileName)
        var oldTextBytes: Data?
        if holdsOldText, !access.isInCloud(oldTextURL) {
            oldTextBytes = try old.bytes(at: oldTextURL)
        }

        if existing.format.isAudio {
            let transcript = try readTranscript(in: old, names: names, for: copy)
            carried.transcript = transcript.carried
            carried.transcriptBeforeCleanup = transcript.beforeCleanup
            if transcript.carried != nil {
                carried.broughtTranscriptNotUsed = broughtTranscript(of: copy)
            }
            // An audiobook's text is its transcript's. Kept beside the new
            // copy: a save its transcript's layer does not account for, and,
            // when the transcript stays behind, the text of a transcript the
            // user edited, which is the only copy of that edit left.
            if holdsOldText {
                try old.requireOnThisMac(oldTextURL)
                let unrecorded = try old.read(oldTextURL) { try FeedItemPackage.unrecordedTranscriptText(of: old.package) }
                let editedTranscriptStaysBehind = transcript.carried == nil && transcript.wasEdited
                carried.unwrittenText = unrecorded ?? (editedTranscriptStaysBehind ? oldTextBytes : nil)
            }
        }
        let oldTextIsWritten = oldTextBytes.map { holdsTextOfPlaces($0, of: existing, hasher: access.hasher) } ?? false
        if !existing.format.isAudio, holdsOldText {
            // An edit on record is kept whatever it takes: never left behind
            // because it is only in the cloud.
            if existing.editedText != nil {
                try old.requireOnThisMac(oldTextURL)
            }
            if let bytes = oldTextBytes, holdsUnwrittenText(bytes, of: existing, hasher: access.hasher) {
                carried.unwrittenText = bytes
            }
        }

        carried.places = carriedPlaces(
            of: existing,
            copy: copy,
            oldText: {
                // The places are moved from the old text only when it is the
                // text they were saved in, as Edit Text moves them only then
                // (`BookTextEditSessions.movedPlaces`): from a save no edit
                // took, they are found in the new text by their words alone.
                guard let oldTextBytes, oldTextIsWritten else { throw CocoaError(.fileReadCorruptFile) }
                return try parsedText(oldTextBytes, at: oldTextURL, title: existing.title, author: existing.author)
            },
            newText: { newText(of: copy, carrying: existing) },
            // An index only in the cloud, or unreadable, moves no place: the
            // places then stay as they were saved.
            oldIndex: { try? old.read(old.package) { try BookInfo.load(from: old.package) }.contentIndex },
            newIndex: { (try? BookInfo.load(from: copy.tmbDirectory))?.contentIndex },
            movedAt: now
        )
        return carried
    }

    /// Whether `bytes`, the content.md of `book`'s old copy, are the text its
    /// places were saved in: the content.md TextMouth last took or wrote,
    /// whose digest the book's record keeps (an edit taken records its own
    /// there). Edit Text moves places from an old text only when it is that
    /// text (`BookTextEditSessions`' moves, T06's branch E), and so does a
    /// replacement (ST04 review, finding 8). False for a save no edit took,
    /// and when the record keeps no digest.
    static func holdsTextOfPlaces(_ bytes: Data, of book: Book, hasher: FingerprintHasher = .md5) -> Bool {
        guard let written = book.textCacheFingerprint?.cache.digest ?? book.editedText?.cacheDigest else { return false }
        return hasher.digestOfData(bytes) == written
    }

    /// Whether `bytes`, the content.md of the text book `book`, hold text
    /// TextMouth did not write, which is kept beside the text that replaces
    /// it rather than lost: an edit the user made with Edit Text, on record
    /// (`Book.editedText`, B12), or a save no edit took, which differs from
    /// the text the book's record says TextMouth last wrote. A book whose
    /// record keeps no fingerprint of its text holds none it can tell.
    /// Replace Existing keeps such text beside the new copy's (ST04), and a
    /// re-read in another encoding beside the new reading (encodingchoice).
    static func holdsUnwrittenText(_ bytes: Data, of book: Book, hasher: FingerprintHasher = .md5) -> Bool {
        if book.editedText != nil { return true }
        return book.textCacheFingerprint != nil && !holdsTextOfPlaces(bytes, of: book, hasher: hasher)
    }

    /// The old copy's package, as a replacement reads it: through `access`,
    /// never downloading anything, every read the cloud refuses becoming the
    /// replacement's refusal (`Refusal.filesInCloud`).
    private struct OldPackage {
        /// The library's copy being replaced.
        let book: Book
        /// How its files are reached.
        let access: MaintenanceFileAccess

        /// The package's folder.
        var package: URL { book.tmbDirectory }

        /// The refusal of a replacement that would leave a file behind in
        /// the cloud.
        var refusal: Refusal { .filesInCloud(title: book.title) }

        /// Throws the refusal when the item at `url` is only in the cloud.
        func requireOnThisMac(_ url: URL) throws {
            if access.isInCloud(url) { throw refusal }
        }

        /// What `body` reads at `url`, with dataless files left in the cloud.
        func read<Value>(_ url: URL, _ body: () throws -> Value) throws -> Value {
            do {
                return try access.read(url, body)
            } catch where DatalessFiles.isDownloadRefusal(error) {
                throw refusal
            }
        }

        /// The bytes of the file at `url`.
        func bytes(at url: URL) throws -> Data {
            try read(url) { try Data(contentsOf: url) }
        }
    }

    // MARK: Two Transcripts (FMT23, B1)

    /// What Replace Existing does with the transcripts of two audiobooks when
    /// the new copy brought one from a file beside its audio (FMT23), as the
    /// duplicate question tells it before it is answered.
    enum TranscriptOutcome: Equatable, Sendable {
        /// Nothing to choose: the new copy brought no transcript, the old copy
        /// has none, or either is not an audiobook. The old copy's
        /// transcript, if any, is kept when the audio is the same, as ever.
        case asBefore
        /// The old copy's transcript is kept when the audio is the same, and
        /// the transcript the new copy brought is not used: recognition made
        /// it, the listener edited or cleaned it up, or this TextMouth cannot
        /// tell, as for one of a later layout or only in the cloud.
        case keepsExisting
        /// The transcript the new copy brought takes the place of the old
        /// copy's, which came from outside and which the listener never
        /// touched.
        case broughtReplacesExisting
    }

    /// What Replace Existing does with the transcripts of `existing`, the
    /// library's copy, and `copy`, the new one (`TranscriptOutcome`): a look
    /// at the new package, and a read of the old transcript's provenance
    /// without its sentences, downloading nothing (`TranscriptStore.provenance`).
    static func transcriptOutcome(replacing existing: Book, with copy: Book) -> TranscriptOutcome {
        guard existing.format.isAudio, copy.format.isAudio,
              TranscriptStore.hasTranscript(of: copy), TranscriptStore.hasTranscript(of: existing) else { return .asBefore }
        guard let provenance = TranscriptStore.provenance(in: existing.tmbDirectory), provenance.isOfThisLayout,
              givesWayToABroughtTranscript(source: provenance.source, isTouched: provenance.isTouched) else {
            return .keepsExisting
        }
        return .broughtReplacesExisting
    }

    /// Whether an old copy's transcript, from `source` (nil for one
    /// recognition made) and touched by the listener or not, gives way to a
    /// transcript the new copy brought: only one from outside the listener
    /// never edited nor cleaned up (B1). The question and the replacement
    /// both ask this, so they never disagree.
    private static func givesWayToABroughtTranscript(source: TranscriptSource?, isTouched: Bool) -> Bool {
        source != nil && !isTouched
    }

    /// A transcript the new copy brought from a file beside its audio.
    struct BroughtTranscript: Equatable, Sendable {
        /// The file's name, when the transcript came from one file; nil when
        /// several tracks each brought one.
        let fileName: String?
    }

    /// The transcript `copy`'s package holds from a file found beside its
    /// audio at import (FMT23), or nil when it holds none.
    private static func broughtTranscript(of copy: Book) -> BroughtTranscript? {
        guard copy.format.isAudio, let provenance = TranscriptStore.provenance(in: copy.tmbDirectory),
              provenance.source?.knownOrigin == .imported else { return nil }
        return BroughtTranscript(fileName: provenance.source?.fileName)
    }

    /// What the old copy's transcript comes to in a replacement: the bytes
    /// the new package takes, when the new copy's audio is the audio
    /// transcribed, with the transcript kept before its cleanup; and whether
    /// the user edited it.
    private struct TranscriptCarried {
        var carried: Data?
        var beforeCleanup: Data?
        var wasEdited = false
    }

    /// Reads the transcript in the old package `old`, whose names are
    /// `names`, as the replacement by `copy` carries it over: for two
    /// audiobooks, when the transcript describes the new copy's audio
    /// (`fitted(_:to:index:sourceMatches:access:)`). A transcript TextMouth cannot read,
    /// or one of a later layout, stays behind with the old package.
    private static func readTranscript(in old: OldPackage, names: [String], for copy: Book) throws -> TranscriptCarried {
        let transcriptURL = TextMouthPaths.transcriptPath(in: old.package)
        guard names.contains(TextMouthPaths.transcriptFileName) else { return TranscriptCarried() }
        try old.requireOnThisMac(transcriptURL)
        let transcript: Transcript
        switch TranscriptStore.read(from: old.package) {
        case .found(let found):
            transcript = found
        case .unsupportedVersion:
            // A later TextMouth's layout, which this one cannot check against
            // the new copy's audio, never vanishes with the old package: it
            // goes as it is, for that TextMouth to check, and this one
            // leaves it alone as it leaves any it cannot read.
            guard copy.format.isAudio else { return TranscriptCarried() }
            return TranscriptCarried(
                carried: try old.bytes(at: transcriptURL),
                beforeCleanup: try beforeCleanupBytes(in: old, names: names)
            )
        case .missing, .inCloud, .unusable:
            return TranscriptCarried()
        }
        var result = TranscriptCarried(wasEdited: transcript.editedAt != nil)
        // A transcript from outside the listener never touched gives way to
        // the one the new copy brought from a file beside its audio (FMT23);
        // one recognition made, or the listener edited or cleaned up, is
        // carried over it, as the question said (`TranscriptOutcome`, B1).
        if copy.format.isAudio, TranscriptStore.hasTranscript(of: copy),
           givesWayToABroughtTranscript(
               source: transcript.source,
               isTouched: transcript.editedAt != nil || transcript.cleanedUp != nil
           ) {
            return result
        }
        guard copy.format.isAudio,
              let index = (try? BookInfo.load(from: copy.tmbDirectory))?.contentIndex,
              let fitted = fitted(
                  transcript,
                  to: copy,
                  index: index,
                  sourceMatches: !copy.md5Hash.isEmpty && old.book.md5Hash == copy.md5Hash,
                  access: old.access
              ) else { return result }

        // The transcript as it was written, unless its file was renamed to
        // the new copy's, when it is written anew in the transcript's form.
        let renamed = fitted != transcript
        if renamed {
            result.carried = try TranscriptStore.encoded(fitted)
        } else {
            result.carried = try old.bytes(at: transcriptURL)
        }

        // The transcript kept before a cleanup, for Undo Cleanup, renamed as
        // the transcript was. One that cannot be read as a transcript is
        // carried as it is.
        if let bytes = try beforeCleanupBytes(in: old, names: names) {
            if renamed, var earlier = try? TranscriptStore.decoded(bytes), earlier.files.count == 1 {
                earlier.files[0].path = fitted.files[0].path
                result.beforeCleanup = try TranscriptStore.encoded(earlier)
            } else {
                result.beforeCleanup = bytes
            }
        }
        return result
    }

    /// The bytes of the transcript kept before a cleanup in the old package
    /// `old`, whose names are `names`; nil when it keeps none.
    /// - Throws: the refusal when it is only in the cloud.
    private static func beforeCleanupBytes(in old: OldPackage, names: [String]) throws -> Data? {
        guard names.contains(TextMouthPaths.transcriptBeforeCleanupFileName) else { return nil }
        let url = TextMouthPaths.transcriptBeforeCleanupPath(in: old.package)
        try old.requireOnThisMac(url)
        return try old.bytes(at: url)
    }

    /// `transcript` as it describes the audio of `copy`, whose audio index
    /// is `index`, or nil when that is not proven, so the question's "when
    /// the audio is the same" holds whenever a transcript is kept. Nothing
    /// is hashed: this runs on the main thread, and an audiobook's files can
    /// take seconds to read whole (ST04 review, finding 7).
    ///
    /// - A new audio file only in the cloud proves nothing.
    /// - A book of one file whose content hash (`Book.md5Hash`, the MD5 of
    ///   the file its import read) is the digest the transcript recorded for
    ///   its one file is that file, whatever its name or date: the
    ///   transcript is kept, its file renamed to the new copy's when the
    ///   names differ, as when the same file is imported from another place
    ///   under another name.
    /// - The same source imported again (`sourceMatches`: the two copies'
    ///   content hashes are equal, an archive's own for a book imported from
    ///   a ZIP, a folder's for a folder of tracks): every file the
    ///   transcript names is the new copy's file at the same path when it has
    ///   the same size. Dates prove nothing here, since extracting an archive
    ///   gives every file a new one (`ArchiveExtraction`).
    /// - Otherwise each new file must be the one transcribed by its path,
    ///   size, and date (`TranscriptTextLoader.audioCheck`), a book of one
    ///   file by its name or the new one; a file whose date moved would need
    ///   its contents hashed, and counts as not proven.
    static func fitted(
        _ transcript: Transcript,
        to copy: Book,
        index: BookContentIndex,
        sourceMatches: Bool = false,
        access: MaintenanceFileAccess = .live
    ) -> Transcript? {
        let locations = TranscriptionPlan.audioFileLocations(of: copy, index: index)
        guard !locations.isEmpty, !locations.contains(where: { access.isInCloud($0.url) }) else { return nil }
        let isOneFile = index.audioFilesInPlayingOrder == nil
        let newName = copy.bookFileURL.lastPathComponent
        /// `transcript` with its one file named as the new copy's.
        func renamed() -> Transcript {
            var renamed = transcript
            renamed.files[0].path = newName
            return renamed
        }
        if isOneFile, transcript.files.count == 1, transcript.files[0].fingerprint.digest == copy.md5Hash {
            return transcript.files[0].path == newName ? transcript : renamed()
        }
        if sourceMatches {
            // The size of each new file there is, by the path a transcript
            // names it by: a file missing is left out, and fails the match.
            let sizes = Dictionary(
                locations.compactMap { location in FileStamp(of: location.url).map { (location.path, $0.byteCount) } },
                uniquingKeysWith: { first, _ in first }
            )
            let sameFiles = Set(sizes.keys) == Set(transcript.files.map(\.path))
                && transcript.files.allSatisfy { sizes[$0.path] == $0.fingerprint.byteCount }
            if sameFiles { return transcript }
        }
        /// Whether `candidate` describes the new copy's files by their
        /// paths, sizes, and dates alone.
        func describesTheAudio(_ candidate: Transcript) -> Bool {
            let check = TranscriptTextLoader.audioCheck(
                of: candidate.audioFiles,
                for: copy,
                audioIndex: index,
                isDataless: access.isDataless,
                hasher: noHashing
            )
            if case .current = check { return true }
            return false
        }
        if describesTheAudio(transcript) { return transcript }
        guard isOneFile, transcript.files.count == 1, transcript.files[0].path != newName else { return nil }
        let candidate = renamed()
        return describesTheAudio(candidate) ? candidate : nil
    }

    /// A hasher that hashes no file, for checks made on the main thread: a
    /// file it is asked to read for its digest is taken for one that
    /// changed.
    private static let noHashing = FingerprintHasher(
        digestOfFile: { _ in throw CocoaError(.featureUnsupported) },
        digestOfData: FingerprintHasher.md5.digestOfData
    )

    /// The new copy's text, as a reader reads its content.md, with the title
    /// and author it will be listed under; nil for a copy without one, as an
    /// audiobook, or whose content.md cannot be read.
    private static func newText(of copy: Book, carrying existing: Book) -> DocumentContent? {
        guard !copy.format.isAudio else { return nil }
        let url = TextMouthPaths.contentMarkdownPath(in: copy.tmbDirectory)
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        var listed = copy
        listed.keepHandEditedMetadata(of: existing)
        return try? parsedText(bytes, at: url, title: listed.title, author: listed.author)
    }

    /// The content.md `bytes`, read from `url`, as a reader reads them for
    /// the book titled `title` by `author`.
    private static func parsedText(_ bytes: Data, at url: URL, title: String, author: String) throws -> DocumentContent {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        return MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: title, bookAuthor: author)
    }

    /// Writes `carried` into the new package at `package`: the copies Edit
    /// Text kept, copied from `oldPackage`; the old text, kept beside the new
    /// text when the two differ; and the transcript.
    /// - Returns: The copy of the old text kept now, when one was made.
    /// - Throws: `TextNotKept`, or the file system's error; the caller undoes
    ///   what was written.
    private static func write(_ carried: Carried, from oldPackage: URL, into package: URL) throws -> URL? {
        let fileManager = FileManager.default
        for name in carried.keptCopyNames {
            try fileManager.copyItem(at: oldPackage.appendingPathComponent(name), to: package.appendingPathComponent(name))
        }
        var keptText: URL?
        let newTextURL = TextMouthPaths.contentMarkdownPath(in: package)
        if let unwritten = carried.unwrittenText, (try? Data(contentsOf: newTextURL)) != unwritten {
            // A copy of the same bytes already carried over serves
            // (`BookTextEditSessions.keepCopy(of:bytes:)`).
            guard let copy = BookTextEditSessions.keepCopy(of: newTextURL, bytes: unwritten) else { throw TextNotKept() }
            keptText = copy
        }
        if let transcript = carried.transcript {
            try transcript.write(to: TextMouthPaths.transcriptPath(in: package), options: .atomic)
            if let beforeCleanup = carried.transcriptBeforeCleanup {
                try beforeCleanup.write(to: TextMouthPaths.transcriptBeforeCleanupPath(in: package), options: .atomic)
            }
        }
        return keptText
    }

    /// The tag of the debug log's lines naming what an undone replacement
    /// could not put back in the new copy's package.
    private static let undoneLogTag = "DUPLICATE_REPLACE_UNDONE"

    /// Puts the new package back as its import published it at
    /// `publishedAt`: moved back from `movedTo`, where it went, and holding
    /// only the names it held before (`namesBefore`), each other entry
    /// removed. What cannot be put back is logged, and left.
    private static func undo(publishedAt: URL, movedTo: URL, namesBefore: Set<String>) {
        let fileManager = FileManager.default
        var package = movedTo
        if movedTo.standardizedFileURL.path != publishedAt.standardizedFileURL.path {
            do {
                try fileManager.moveItem(at: movedTo, to: publishedAt)
                package = publishedAt
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "\(undoneLogTag): the new copy's package \(publishedAt.lastPathComponent) could not move back "
                        + "to where it was imported: \(error.localizedDescription)"
                )
            }
        }
        // A package always holds its record, so an empty listing of what it
        // held can only be a mistake: nothing is removed on it.
        guard !namesBefore.isEmpty else { return }
        for name in FeedItemPackage.entryNames(of: package) where !namesBefore.contains(name) {
            do {
                try fileManager.removeItem(at: package.appendingPathComponent(name))
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "\(undoneLogTag): \(name) could not be removed from the new copy's package "
                        + "\(package.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: A Copy Read Again in the Old Copy's Reading (braillecodes, encodingchoice)

    /// How the new copy is read again before it takes the place of the old
    /// one: the choice the listener made for the old copy in Book Information
    /// that the import of the new copy could not know.
    private enum CopyReading: Equatable {
        /// In the braille file characters with this id, a BRF or BRL book's
        /// (braillecodes); an id this TextMouth does not know is refused by
        /// name when the copy is read.
        case brailleFileCode(id: String)
        /// In the text encoding of this option, a plain-text, Markdown, or
        /// HTML book's (encodingchoice).
        case textEncoding(TextEncodingOption)
    }

    /// How the new copy `copy` is read again before it takes the place of
    /// `existing`, or nil when it keeps the reading its import gave it: the
    /// braille file characters of a braille copy
    /// (`brailleFileCodeToReadAgain(replacing:with:)`), or the text encoding
    /// of a text copy (`textEncodingToReadAgain(replacing:with:)`). A book is
    /// of one kind or the other, so at most one applies.
    private static func readingToCarry(replacing existing: Book, with copy: Book) -> CopyReading? {
        if let id = brailleFileCodeToReadAgain(replacing: existing, with: copy) {
            return .brailleFileCode(id: id)
        }
        return textEncodingToReadAgain(replacing: existing, with: copy).map(CopyReading.textEncoding)
    }

    /// The braille file characters, by their id, that the new copy `copy`
    /// is read in again before it takes the place of `existing` (braillecodes
    /// review, finding 3), or nil when it keeps the reading its import gave
    /// it. The import read it in the Braille setting's characters, while the
    /// user may have chosen others for the library's copy in Book
    /// Information, which a replacement must not undo. It is read again
    /// when all of these hold, the new copy's bytes looked at last:
    /// - both are BRF or BRL braille books (`Book.offersBrailleFileCodeChoice`),
    ///   whose seven-bit codes no byte tells apart;
    /// - their files are the same bytes (the same content hash, `md5Hash`),
    ///   so the old copy's characters are known to be the new copy's file's;
    /// - the characters that stand for the old copy, between its row and its
    ///   record (`Book.recordedBrailleFileCode()`), are not the new copy's,
    ///   each as its stored code names them (`codeID(ofStored:)`): none
    ///   names North American Braille ASCII, and an id this TextMouth does
    ///   not know names itself, which the reading then refuses by name;
    /// - the new copy's bytes did not say which characters they are
    ///   (`BrailleFileReader.certainCode(ofFileAt:)`): a file of Unicode
    ///   braille patterns keeps them, whatever the old copy records, as a
    ///   book whose code an earlier TextMouth dropped records none
    ///   (`Book.brailleFileCodeForReading()`).
    /// The id is explicit, North American Braille ASCII's included, as every
    /// reading again records one.
    static func brailleFileCodeToReadAgain(replacing existing: Book, with copy: Book) -> String? {
        guard existing.offersBrailleFileCodeChoice, copy.offersBrailleFileCodeChoice,
              !copy.md5Hash.isEmpty, existing.md5Hash == copy.md5Hash else { return nil }
        let standing = codeID(ofStored: existing.recordedBrailleFileCode())
        guard standing != codeID(ofStored: copy.brailleFileCode),
              BrailleFileReader.certainCode(ofFileAt: copy.bookFileURL) == nil else { return nil }
        return standing
    }

    /// The text encoding that the new copy `copy` is read in again before it
    /// takes the place of `existing`, or nil when it keeps the reading its
    /// import gave it. The import read it as it reads any new file, while the
    /// listener may have chosen an encoding for the library's copy in Book
    /// Information because that reading was wrong, which a replacement must
    /// not undo. It is read again when all of these hold, the new copy's
    /// bytes looked at last:
    /// - both are books of one text format that offers the choice
    ///   (`Book.offersTextEncodingChoice`);
    /// - the old copy's encoding was chosen by the listener
    ///   (`TextEncodingRecord.isChosen`), as it stands between its row and
    ///   its record (`Book.recordedTextEncodingRecord()`). A guess or
    ///   Automatic is what the import of the new copy does by itself, so
    ///   there is nothing to carry;
    /// - the choice is about this file: the two files are the same bytes
    ///   (the same content hash), or the new file's bytes can be read in the
    ///   choice and name no encoding of their own
    ///   (`bytesMayBeReadInChoice(_:of:)`): no byte-order mark, no valid
    ///   UTF-8, no declaration, and not a structure the decoder recognises
    ///   (well-formed ISO-2022-JP), their import only guessed or fell back,
    ///   and every byte is valid in the encoding chosen. A new file that
    ///   names its encoding, or that the choice cannot read, is not the file
    ///   the choice was made about, and keeps the reading its import gave it
    ///   (Replace Existing goes ahead with it).
    /// The option is the old copy's choice as Book Information offers it
    /// (`TextEncodingChoices.option(forIdentifier:)`); an identifier no
    /// option names, as a later TextMouth may have recorded, is carried as
    /// it is, for the reading to refuse by name.
    static func textEncodingToReadAgain(replacing existing: Book, with copy: Book) -> TextEncodingOption? {
        guard existing.format == copy.format,
              existing.offersTextEncodingChoice, copy.offersTextEncodingChoice else { return nil }
        let standing = existing.recordedTextEncodingRecord()
        guard standing.isChosen, let identifier = standing.identifier else { return nil }
        let isSameFile = !copy.md5Hash.isEmpty && existing.md5Hash == copy.md5Hash
        guard isSameFile || bytesMayBeReadInChoice(identifier, of: copy) else { return nil }
        return TextEncodingChoices.option(forIdentifier: identifier) ?? .encoding(identifier)
    }

    /// Whether the listener's choice of the encoding `identifier`, made for
    /// another file, is also the right reading of the text book `book`'s
    /// bytes (a different file from the one chosen about). Both must hold:
    /// - the bytes name no encoding of their own. They are read as an import
    ///   reads them, guessing, without logging; the reading must rest on the
    ///   guesser's judgment (`DecodedText.Basis.guess`) or on the
    ///   Windows-1252 fallback, never on a byte-order mark, unmarked Unicode,
    ///   valid UTF-8, or a declaration. A guess the decoder makes by the
    ///   bytes' structure (well-formed ISO-2022-JP, whose escape sequences
    ///   are ASCII and so valid in many of the encodings a listener may have
    ///   chosen) is a recognition, not a guess, and is kept
    ///   (`TextEncodingGuesser.guessSevenBit(_:)`);
    /// - every byte is valid in `identifier`, read strictly as the re-read
    ///   will read it (`EncodingPolicy.chosen(_:)`). A copy the choice cannot
    ///   read would be refused, and so could never replace the book.
    /// False for a file that cannot be read, or whose declaration its bytes
    /// contradict.
    private static func bytesMayBeReadInChoice(_ identifier: String, of book: Book) -> Bool {
        guard let bytes = try? Data(contentsOf: book.bookFileURL) else { return false }
        let fileName = book.bookFileURL.lastPathComponent
        // Recognised by structure: the import read it by what the bytes are.
        guard TextEncodingGuesser.guessSevenBit(bytes) == nil,
              let decoded = try? TextFileDecoder.decode(bytes, fileName: fileName, format: book.format, policy: .guess),
              decoded.basis == .guess || decoded.basis == .fallback else { return false }
        // Valid in the choice: the re-read refuses bytes that are not.
        return (try? TextFileDecoder.decode(bytes, fileName: fileName, format: book.format, policy: .chosen(identifier))) != nil
    }

    /// The id of the braille file characters the stored braille file code
    /// `stored` names (`BrailleFileCode.code(forStored:)`): a known code's
    /// own id, North American Braille ASCII's for none (nil or empty), and an
    /// id this TextMouth does not know as it is stored.
    private static func codeID(ofStored stored: String?) -> String? {
        BrailleFileCode.code(forStored: stored)?.id ?? stored
    }

    /// Reads the new copy `copy` again as `reading` says, the old copy's
    /// (`readingToCarry(replacing:with:)`), as Book Information reads a book
    /// again with other braille file characters or another encoding
    /// (`LibraryViewModel.rereadText(of:as:access:isOpenInReader:)`): its
    /// file checked to read so before anything is written, its content.md
    /// written anew, and the choice recorded as decided, with the new text's
    /// analysis, in its package record, which still names the copy's own ID.
    /// The replacement's later write of that record keeps the choice, a
    /// record's decision standing over a row's
    /// (`BrailleFileCodeRecord.standing(row:recorded:)`,
    /// `TextEncodingRecord.standing(row:recorded:)`), and the row returned
    /// holds it too, so the two agree. Nothing is downloaded (`access`), no
    /// reader has the copy open, and the debug log says it as a re-read's
    /// (BRAILLE_FILE_CODE_CHANGED, TEXT_ENCODING_CHANGED).
    /// - Returns: The copy as its package now records it, with its files as
    ///   its import wrote them, to put back.
    /// - Throws: `Refusal.copyNotReadAgain`, with the reading's own
    ///   sentence, when the copy could not be read so (bytes not valid in
    ///   the encoding chosen, for one); nothing changed then. An id of braille
    ///   file characters this TextMouth does not know is refused by name
    ///   before anything is read, as every reading of a book refuses it
    ///   (`BrailleFileError.unknownFileCode`), in the words the re-read gives
    ///   a reading that failed.
    private static func readCopyAgain(_ copy: Book, as reading: CopyReading, access: MaintenanceFileAccess) throws -> CopyReadAgain {
        let choice: TextRereadChoice
        switch reading {
        case .brailleFileCode(let id):
            guard let code = BrailleFileCode.code(withID: id) else {
                throw Refusal.copyNotReadAgain(TextEncodingWording.failedRefusal(
                    bookTitle: copy.title, reason: BrailleFileError.unknownFileCode(id).localizedDescription
                ))
            }
            choice = .brailleFileCode(code)
        case .textEncoding(let option):
            choice = .textEncoding(option)
        }
        // The files the re-read writes, as the import wrote them.
        let filesBefore = [
            MarkdownCacheService.cacheURL(for: copy),
            TextMouthPaths.contentIndexPath(in: copy.tmbDirectory),
            TextMouthPaths.bookInfoPath(in: copy.tmbDirectory),
        ].map { PackageFileBeforeInstall($0) }
        let reread = LibraryViewModel.rereadText(
            of: copy, as: choice, access: access, isOpenInReader: { _ in false }
        )
        switch reread {
        case .refused(let sentence):
            throw Refusal.copyNotReadAgain(sentence)
        case let .readAgain(update, _, keptCopy):
            if let line = LibraryViewModel.rereadLogLine(title: copy.title, choice: choice, update: update, keptCopy: keptCopy) {
                DiagnosticLog.event(.storage, line)
            }
            // The row takes what the record now holds, as a library row takes
            // a re-read's commit: the new text's analysis, and the choice.
            var readCopy = copy
            update.summary?.apply(to: &readCopy)
            return CopyReadAgain(copy: readCopy, filesBefore: filesBefore)
        }
    }

    /// A copy read again in the old copy's reading
    /// (`readCopyAgain(_:as:access:)`), and its files as its import wrote
    /// them, which a replacement that does not go ahead puts back.
    fileprivate struct CopyReadAgain {
        /// The new copy as its package now records it: read as the old copy
        /// is, with the new text's analysis.
        let copy: Book
        /// content.md, contentIndex.json, and bookInfo.json as the import
        /// wrote them, before the copy was read again.
        let filesBefore: [PackageFileBeforeInstall]

        /// Puts back, with its bytes and dates, each of the copy's files
        /// written since it was kept: by the re-read, or by a commit of the
        /// replacement's record that failed after it, so the new package is
        /// as its import published it. Called with the package where its
        /// import published it, where the files were kept. What cannot be put
        /// back is logged, and nothing is put back when a file the re-read
        /// wrote over could not be kept (`PackageFileBeforeInstall.putBack`).
        func putBack() {
            // Each file's stamp now stands for the write to undo, so a file
            // written since is put back, and one never written is left.
            PackageFileBeforeInstall.putBack(
                filesBefore.map { (file: $0, written: FileStamp(of: $0.url)) },
                of: copy,
                after: "the replacement",
                logTag: DuplicateReplacement.undoneLogTag
            )
        }
    }
}

// MARK: - The Book's Own Settings and Hand Edits

extension Book {
    /// This book under the ID `id`, every other field as it is: made through
    /// the book's record (`makeBookInfo()`, and its inverse,
    /// `init(record:filePath:folderPath:tmbDirectoryName:)`), which carries
    /// every field a book keeps, so a field added later comes along too.
    func withID(_ id: UUID) -> Book {
        var info = makeBookInfo()
        info.metadata.bookID = id
        var book = Book(record: info, filePath: filePath, folderPath: folderPath, tmbDirectoryName: tmbDirectoryName)
        book.fileLocation = fileLocation
        return book
    }

    /// Takes `other`'s own settings in place of this book's
    /// (`hasOwnSettings`): its voice, speed, and pitch, what happens at its
    /// end, and the units of its skips forward and back. Skipped headings
    /// are places, which move with the text (`setSkippedHeadings(_:)`).
    fileprivate mutating func takeOwnSettings(of other: Book) {
        localVoiceID = other.localVoiceID
        localWPM = other.localWPM
        localPitch = other.localPitch
        localEndOfBookBehavior = other.localEndOfBookBehavior
        localSkipForwardUnit = other.localSkipForwardUnit
        localSkipBackwardUnit = other.localSkipBackwardUnit
    }

    /// Takes the values of the metadata fields the user edited by hand in
    /// `other` (`HandEdits`), and records them as edited by hand here too, as
    /// the launch's metadata refresh never replaces such a field. Fields the
    /// user did not edit keep this book's values.
    fileprivate mutating func keepHandEditedMetadata(of other: Book) {
        guard let edited = other.handEdits?.fields, !edited.isEmpty else { return }
        let values = other.editableMetadata
        for field in edited {
            if let value = field.value(in: values) {
                field.set(value, in: &self)
            }
        }
        markEditedByHand(Set(edited))
    }
}

// MARK: - A New Copy Waiting for Its Answer

/// The hidden file a duplicate's new copy holds in its package while the
/// question about it ("Duplicate Book Found") waits for the listener's
/// answer (`LibraryViewModel.addBookCheckingDuplicate`).
///
/// The question lives only in memory, in the library's queue of import
/// questions, while the new copy's package is already published in its
/// library folder. A quit, a logout, or a crash before the answer leaves
/// that package behind, and every later launch would take it for one an
/// interrupted import left: hidden for good while the library refuses a
/// second book with the same content, back as a book once the listener
/// deletes the copy it matched, or adopted at once, a Keep Both never
/// chosen, when the two copies matched only by the file they came from. So
/// the marker is written before the question is asked; every answer that
/// keeps the copy removes it just before the library's index names the
/// copy, so no package the library lists ever holds it; Cancel discards
/// the package with it; and no adoption of orphaned packages ever adopts a
/// package holding it (`FileImportService.adoptOrphanedTMBPackages`). The
/// launch's repair discards each such package whose question no longer
/// waits (`LibraryViewModel.adoptOrphanedPackages`).
///
/// Only the file's presence counts, so it is empty: unlike
/// `RemovedFromLibraryMarker`, it is never read back, and nothing in it
/// needs keeping, since a copy's original file is deleted only once the
/// copy is kept, never while its question waits.
enum DuplicateQuestionMarker {
    /// The marker's file name, at the top of the new copy's package. It is
    /// hidden, so nothing takes it for the book's own content
    /// (`FileImportService.isPackageContentName`).
    static let fileName = ".awaitingDuplicateAnswer"

    /// Where the marker is, or would be, in the package `package`.
    static func url(in package: URL) -> URL {
        package.appendingPathComponent(fileName)
    }

    /// Whether the package `package` holds the marker.
    static func isHeld(by package: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: package).path)
    }

    /// Writes the marker into the package `package`, replacing any earlier
    /// one. The write is atomic, as `RemovedFromLibraryMarker`'s is, so the
    /// marker is either absent or whole.
    /// - Throws: why the marker could not be written.
    static func write(into package: URL) throws {
        try Data().write(to: url(in: package), options: .atomic)
    }

    /// Removes the marker from the package `package`, once an answer keeps
    /// its copy. A package without one is left as it is.
    /// - Throws: why a marker that is there could not be removed.
    static func remove(from package: URL) throws {
        let marker = url(in: package)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
    }
}

/// The packages holding a `DuplicateQuestionMarker` that an adoption of
/// orphaned packages passed over (`FileImportService.adoptOrphanedTMBPackages`),
/// gathered for the launch's repair, which discards those whose questions
/// no longer wait (`LibraryViewModel.adoptOrphanedPackages`). An adoption
/// given none of these only passes such packages over.
final class UnansweredDuplicates {
    /// The packages passed over, in the order the adoption found them.
    private(set) var packages: [URL] = []

    /// Records the package at `package`.
    func record(_ package: URL) {
        packages.append(package)
    }
}
