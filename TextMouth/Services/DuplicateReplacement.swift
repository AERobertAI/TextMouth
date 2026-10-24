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
///   count time in its recording (P08), so they stay as they are;
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
/// The work is in two parts, so that the library changes only once the old
/// copy's package is gone:
/// 1. `prepare(replacing:with:access:now:)` reads what is carried over,
///    refusing before anything is written when part of it is only in the
///    cloud, then writes it into the new copy's package and moves that
///    package into the old copy's folder. The row it returns has the old
///    copy's ID, while the new package's record keeps the import's own until
///    the library saves that row, so a stop before the old package goes
///    never leaves two records naming one book.
/// 2. The library deletes the old copy's package, then puts the row in the
///    old row's place (`LibraryViewModel+Duplicates`). A deletion that fails
///    undoes the first part (`Preparation.undo()`), and the question stays.
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

        /// The refusal as the question's sheet shows it and VoiceOver
        /// speaks it.
        var sentence: String {
            switch self {
            case .inUse(let use, let title):
                return use.refusal(of: "“\(title)”", doing: "replacing it", retry: DuplicateReplacement.retry)
            case .audioBeingEdited(let title):
                return "The audio of “\(title)” is being edited. Close the audio editor, or wait until it has saved, "
                    + "then \(DuplicateReplacement.retry)."
            case .filesInCloud(let title):
                return "Some of the files of “\(title)” are only in the cloud, and replacing it now would leave them behind. "
                    + "Download the book, then \(DuplicateReplacement.retry)."
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
    /// which reads the old text only when some place does not stand in the
    /// new one; otherwise, as they are. Nothing is said or shown; when any
    /// place moved, the debug log gets the relocator's counts
    /// (PLACES_RELOCATED).
    ///
    /// - An audiobook's places count time in its recording (P08), and stay.
    /// - Places nothing could move (none saved, or a reading position at the
    ///   very start) stay, and neither text is read.
    /// - With no new text to read (`newText` gives nil), the places stay,
    ///   and the reader finds them by their words when it first loads the
    ///   new copy.
    /// - With no old text to read (`oldText` throws: it is gone, or only in
    ///   the cloud), the places are found in the new text by their words
    ///   alone, as a reader's load finds them
    ///   (`PlaceRelocator.relocate(_:within:movedAt:)`), and a place nothing
    ///   finds stays as it was saved.
    static func carriedPlaces(
        of existing: Book,
        copy: Book,
        oldText: () throws -> DocumentContent,
        newText: () -> DocumentContent?,
        movedAt date: Date
    ) -> PlaceRelocator.Places {
        let saved = existing.relocatablePlaces
        guard areSameKind(existing, copy), !copy.format.isAudio, existing.holdsPlacesToMove, let newText = newText() else {
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

    // MARK: Preparing the New Copy's Package

    /// The new copy's package, made ready to take the old copy's place, and
    /// what the library needs to finish the replacement or undo it.
    struct Preparation {
        /// The library row the new copy becomes (`carriedBook`), at its
        /// package's new place.
        let book: Book
        /// Whether the old copy's transcript went into the new package.
        let keptTranscript: Bool
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

        /// Puts the new package back as its import published it, as a
        /// replacement whose old copy could not be deleted must leave it:
        /// moved back to where it was published, without anything carried
        /// into it. What cannot be put back is logged; the question stays
        /// either way.
        func undo() {
            DuplicateReplacement.undo(publishedAt: publishedAt, movedTo: movedTo, namesBefore: namesBefore)
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
        /// The old copy's places as the new copy keeps them.
        var places = PlaceRelocator.Places()
    }

    /// Makes the new copy `copy`'s package ready to take the place of
    /// `existing`, the library's copy, and returns the row it becomes.
    ///
    /// Everything carried over is read first, without downloading anything
    /// (`access`): the copies Edit Text kept, the old text when it holds text
    /// TextMouth did not write, the transcript when the new copy's audio is
    /// the audio transcribed, and both texts, for the places. Only then is
    /// anything written: those files go into the new package, which then
    /// moves into `existing`'s folder. A failure while writing undoes what
    /// was written before it throws.
    ///
    /// - Throws: the deletion's own error for a row naming no package the
    ///   library manages (`FileImportService.managedPackageURLForDeletion`);
    ///   `Refusal.filesInCloud` when something carried over is only in the
    ///   cloud, before anything is written; `TextNotKept` when the old text
    ///   could not be kept beside the new one; or the file system's error.
    ///   The new package is then as its import published it.
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
        let carried = try readCarried(from: existing, for: copy, access: access, now: now)
        // What the import published, listed before anything is carried in,
        // which an undo leaves: a package that cannot be listed fails here,
        // with nothing written, rather than give an undo nothing to keep.
        let namesBefore = Set(try FeedItemPackage.listedEntryNames(of: publishedAt))
        let destination = TextMouthPaths.tmbPath(folderPath: existing.folderPath, tmbName: copy.tmbDirectoryName)
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
            with: copy,
            places: carried.places,
            location: location(of: copy, movedTo: movedTo, folderPath: existing.folderPath)
        )
        return Preparation(
            book: book,
            keptTranscript: carried.transcript != nil,
            keptText: keptText,
            publishedAt: publishedAt,
            movedTo: movedTo,
            namesBefore: namesBefore
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
        } else if holdsOldText {
            if existing.editedText != nil {
                // An edit on record is kept whatever it takes: never left
                // behind because it is only in the cloud.
                try old.requireOnThisMac(oldTextURL)
                carried.unwrittenText = oldTextBytes
            } else if let bytes = oldTextBytes, let written = existing.textCacheFingerprint?.cache.digest,
                      access.hasher.digestOfData(bytes) != written {
                // A save no edit took: not the text TextMouth wrote.
                carried.unwrittenText = bytes
            }
        }

        carried.places = carriedPlaces(
            of: existing,
            copy: copy,
            oldText: {
                guard let oldTextBytes else { throw CocoaError(.fileReadNoSuchFile) }
                return try parsedText(oldTextBytes, at: oldTextURL, title: existing.title, author: existing.author)
            },
            newText: { newText(of: copy, carrying: existing) },
            movedAt: now
        )
        return carried
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
    /// (`fitted(_:to:index:access:)`). A transcript TextMouth cannot read,
    /// or one of a later layout, stays behind with the old package.
    private static func readTranscript(in old: OldPackage, names: [String], for copy: Book) throws -> TranscriptCarried {
        let transcriptURL = TextMouthPaths.transcriptPath(in: old.package)
        guard names.contains(TextMouthPaths.transcriptFileName) else { return TranscriptCarried() }
        try old.requireOnThisMac(transcriptURL)
        guard case .found(let transcript) = TranscriptStore.read(from: old.package) else { return TranscriptCarried() }
        var result = TranscriptCarried(wasEdited: transcript.editedAt != nil)
        guard copy.format.isAudio,
              let index = (try? BookInfo.load(from: copy.tmbDirectory))?.contentIndex,
              let fitted = fitted(transcript, to: copy, index: index, access: old.access) else { return result }

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
        let beforeCleanupURL = TextMouthPaths.transcriptBeforeCleanupPath(in: old.package)
        if names.contains(TextMouthPaths.transcriptBeforeCleanupFileName) {
            try old.requireOnThisMac(beforeCleanupURL)
            let bytes = try old.bytes(at: beforeCleanupURL)
            if renamed, var earlier = try? TranscriptStore.decoded(bytes), earlier.files.count == 1 {
                earlier.files[0].path = fitted.files[0].path
                result.beforeCleanup = try TranscriptStore.encoded(earlier)
            } else {
                result.beforeCleanup = bytes
            }
        }
        return result
    }

    /// `transcript` as it describes the audio of `copy`, whose audio index
    /// is `index`, or nil when it does not: as it is, when the new copy's
    /// audio files are the ones transcribed, each the same size with the
    /// same contents (`TranscriptTextLoader.audioCheck`); or, for a book of
    /// one audio file, with that file renamed to the new copy's, when only
    /// its name differs, as when the same file is imported from another
    /// place under another name.
    static func fitted(
        _ transcript: Transcript,
        to copy: Book,
        index: BookContentIndex,
        access: MaintenanceFileAccess = .live
    ) -> Transcript? {
        /// Whether `candidate` describes the new copy's audio.
        func describesTheAudio(_ candidate: Transcript) -> Bool {
            let check = TranscriptTextLoader.audioCheck(
                of: candidate.audioFiles,
                for: copy,
                audioIndex: index,
                isDataless: access.isDataless,
                hasher: access.hasher
            )
            if case .current = check { return true }
            return false
        }
        if describesTheAudio(transcript) { return transcript }
        let newName = copy.bookFileURL.lastPathComponent
        guard index.audioFilesInPlayingOrder == nil, transcript.files.count == 1, transcript.files[0].path != newName else {
            return nil
        }
        var renamed = transcript
        renamed.files[0].path = newName
        return describesTheAudio(renamed) ? renamed : nil
    }

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
                    "DUPLICATE_REPLACE_UNDONE: the new copy's package \(publishedAt.lastPathComponent) could not move back "
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
                    "DUPLICATE_REPLACE_UNDONE: \(name) could not be removed from the new copy's package "
                        + "\(package.lastPathComponent): \(error.localizedDescription)"
                )
            }
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
