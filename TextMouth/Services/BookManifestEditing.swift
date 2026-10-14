import Foundation
import os

// MARK: - Which Books (FR17)

/// Edit Manifest in Default Editor and Edit Manifest With… (FR17): a
/// multi-track audiobook's manifest.json opens in the user's own editor, and
/// TextMouth takes what the user saves as the book's arrangement, as Edit
/// Text takes a book's edited text (FR05, `BookTextEditor`).
///
/// A ZIP's tracks sit unzipped in the book's package, with the ZIP's
/// manifest beside them, so a manifest edited there rearranges the book
/// without importing it again (the user's answer to question 8 of October
/// 13, 2026: "yes A").
enum BookManifestEditing {
    /// Whether `book`'s manifest can be edited, given whether its audio is
    /// a folder of tracks played one per heading (`isTrackFolder`, as
    /// `TrackFolderBooks` has found it): an audiobook of the library's own,
    /// in a package of its own (`LibraryAudioCommand.isAudioEditable`),
    /// never a feed's item, which the user decided is not editable (FR11,
    /// question 4). A single-file audiobook and a converted DAISY book,
    /// whose manifest's sections TextMouth writes itself, are no track
    /// folders, so neither is offered.
    static func canEditManifest(of book: Book, isTrackFolder: Bool) -> Bool {
        LibraryAudioCommand.isAudioEditable(book) && isTrackFolder
    }

    /// Whether `book`'s manifest can be edited, as the app knows which
    /// audiobooks play a folder of tracks (`TrackFolderBooks.shared`).
    @MainActor
    static func canEditManifest(of book: Book) -> Bool {
        canEditManifest(of: book, isTrackFolder: TrackFolderBooks.shared.contains(book.id))
    }

    /// Whether `book`'s audio is a folder of tracks in its own package that
    /// plays one track per heading (`isTrackFolder(_:isDataless:)`). False
    /// for any book `canEditManifest(of:isTrackFolder:)` refuses whatever
    /// its audio, and for a book whose audio folder is not inside its
    /// package. Looks at the disk: call it off the main thread.
    static func hasTrackFolder(_ book: Book, isDataless: (URL) -> Bool = DatalessFiles.isDataless) -> Bool {
        guard canEditManifest(of: book, isTrackFolder: true),
              book.filePath.hasPrefix(book.tmbDirectory.path + "/") else { return false }
        return isTrackFolder(book.bookFileURL, isDataless: isDataless) == true
    }

    /// Whether `folder` is a folder of tracks that plays one track per
    /// heading, as the reader's parse plays it (`AudioBookParser.parseDirectory`):
    /// a folder without a manifest, or whose manifest gives no sections
    /// (`AudioManifest.segments`), the layout the content index calls
    /// `multiFile`. A manifest that cannot be read is read as none, as the
    /// parse reads it, so its tracks play one per heading too.
    ///
    /// False for a file, which is a single-file audiobook, for a folder
    /// whose manifest gives sections, as a converted DAISY book's does, and
    /// for nothing at all. Nil when it cannot be told without downloading
    /// (FR02): the folder or its manifest is only in the cloud. Reads only
    /// the manifest, never a track.
    static func isTrackFolder(_ folder: URL, isDataless: (URL) -> Bool = DatalessFiles.isDataless) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // The folder is listed to find a manifest inside its one folder,
        // which would download the listing of a folder only in the cloud.
        guard !isDataless(folder) else { return nil }
        guard let location = AudioManifestLocation.find(in: folder) else { return true }
        guard !isDataless(location.url) else { return nil }
        guard let data = try? Data(contentsOf: location.url),
              let manifest = try? AudioManifest.decoded(from: data) else { return true }
        return (manifest.segments ?? []).isEmpty
    }
}

// MARK: - The Manifest's File (FR17)

/// A folder of tracks' manifest.json as Edit Manifest finds it, writes it
/// for a book without one, and writes every change TextMouth itself makes
/// to it, through one function (`write(_:at:of:sessions:)`).
enum BookManifestFile {
    /// Why a book's manifest could not be readied for editing.
    enum PreparationFailure: Error, Equatable {
        /// The book's audio is not a folder of tracks played one per
        /// heading, or it is gone.
        case notTrackFolder
        /// The folder, or its manifest, is only in the cloud (FR02).
        case inCloud
        /// The manifest could not be written or read, with why.
        case failed(String)
    }

    /// A manifest ready to edit: where it is, and its fingerprint, the
    /// baseline its edits are told from.
    struct Ready: Sendable {
        let location: AudioManifestLocation
        let fingerprint: FileFingerprint
    }

    /// The manifest of `book`'s folder of tracks, ready to edit, as storage
    /// work, so a data-directory move or a folder edit never moves the
    /// folder while it is written: found where the reader finds it, or, for
    /// a book without one, written first from the book as it is
    /// (`generated(for:names:)`). Reads only what is on this Mac. Runs off
    /// the main thread.
    static func prepare(
        _ book: Book,
        sessions: BookManifestEditSessions = .shared,
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Result<Ready, PreparationFailure> {
        sessions.boundary.perform(.contentAnalysis) { _ in
            let current = sessions.boundary.rebasedToCurrent(book)
            let folder = current.bookFileURL
            switch BookManifestEditing.isTrackFolder(folder, isDataless: isDataless) {
            case nil:
                return .failure(.inCloud)
            case false?:
                return .failure(.notTrackFolder)
            case true?:
                break
            }
            let location: AudioManifestLocation
            if let found = AudioManifestLocation.find(in: folder) {
                location = found
            } else {
                location = AudioManifestLocation.forNewManifest(in: folder)
                do {
                    let names = try AudioBookParser.trackPaths(in: folder).map(location.name(ofTrackAt:))
                    try write(generated(for: current, names: names), at: location, of: current.id, sessions: sessions)
                    DiagnosticLog.event(.storage, "MANIFEST_WRITTEN: \(current.title): \(names.count) track(s), for editing")
                } catch {
                    return .failure(.failed(error.localizedDescription))
                }
            }
            guard let fingerprint = FileFingerprint(of: location.url, hasher: hasher) else {
                return .failure(.failed(BookManifestEditWording.unreadable))
            }
            return .success(Ready(location: location, fingerprint: fingerprint))
        }
    }

    /// The manifest a book without one is given before it is edited
    /// (FR17, item 3): its tracks, `names`, spelled as the manifest spells
    /// them, in the order they play now, each with the title its heading
    /// shows now, in the tracks format; its present title and author; and
    /// no pause between tracks, since a book without a manifest plays
    /// straight on from track to track, and opening it for editing must not
    /// change that. A book without a manifest is arranged as `AudioTrackPlan`
    /// arranges a folder without one, so that plan gives the order and the
    /// titles.
    static func generated(for book: Book, names: [String]) -> AudioManifest {
        let plan = AudioTrackPlan(arranging: names, by: nil)
        var manifest = AudioManifest()
        manifest.title = book.title
        manifest.author = book.author
        manifest.pauseBetweenTracksMs = 0
        manifest.tracks = plan.tracks.map { track in
            .track(AudioManifestTrack(file: track.name, title: track.title))
        }
        return manifest
    }

    /// `manifest` as TextMouth writes a manifest into a book's package:
    /// indented, its keys sorted, its slashes as typed, so a person can read
    /// and edit it.
    static func encoded(_ manifest: AudioManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// The one write of a book's manifest by TextMouth itself (FR17): the
    /// manifest Edit Manifest writes for a book without one, the title and
    /// author a metadata edit keeps in step, and a track the audio editor
    /// renames. It writes `manifest` at `location` at once, replacing the
    /// file whole, and tells the session editing the book `bookID`, if any,
    /// so its next check starts from what was written rather than take
    /// TextMouth's own write for the user's edit.
    static func write(
        _ manifest: AudioManifest,
        at location: AudioManifestLocation,
        of bookID: UUID,
        sessions: BookManifestEditSessions = .shared,
        hasher: FingerprintHasher = .md5
    ) throws {
        try write(data: encoded(manifest), at: location, of: bookID, sessions: sessions, hasher: hasher)
    }

    /// Writes `data`, a manifest's bytes, at `location`, as `write(_:at:of:sessions:hasher:)`
    /// does: the one place a manifest of a book's package is written.
    static func write(
        data: Data,
        at location: AudioManifestLocation,
        of bookID: UUID,
        sessions: BookManifestEditSessions = .shared,
        hasher: FingerprintHasher = .md5
    ) throws {
        try data.write(to: location.url, options: .atomic)
        if let stamp = FileStamp(of: location.url) {
            sessions.noteWritten(bookID, FileFingerprint(stamp: stamp, digest: hasher.digestOfData(data)))
        }
    }

    /// Changes the manifest at `location` of the book `bookID` with
    /// `change`, which is given the manifest's one JSON object, and writes
    /// it back through `write(data:at:of:sessions:hasher:)` when `change`
    /// changed it. The object is changed as JSON, so every key and value
    /// the user wrote stays, a key TextMouth does not read included; the
    /// file is written again indented, with its keys sorted, as TextMouth
    /// writes every manifest. A manifest that is not one JSON object, as
    /// while the user is midway through an edit, is left as it is.
    ///
    /// - Returns: Whether the manifest was written.
    @discardableResult
    static func change(
        manifestAt location: AudioManifestLocation,
        of bookID: UUID,
        sessions: BookManifestEditSessions = .shared,
        _ change: (inout [String: Any]) -> Void
    ) throws -> Bool {
        let data = try Data(contentsOf: location.url)
        guard var object = (try? JSONSerialization.jsonObject(with: AudioManifest.withoutByteOrderMark(data))) as? [String: Any] else {
            return false
        }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let before = try JSONSerialization.data(withJSONObject: object, options: options)
        change(&object)
        let after = try JSONSerialization.data(withJSONObject: object, options: options)
        guard after != before else { return false }
        try write(data: after, at: location, of: bookID, sessions: sessions)
        return true
    }

    /// Keeps `title` and `author` in the manifest of `book`'s folder of
    /// tracks, nil leaving either as the manifest has it: the manifest's
    /// side of the one write of a manifest book's title and author
    /// (`LibraryViewModel.setTitleAndAuthor(ofManifestBook:title:author:)`).
    /// A book without a manifest is given one first, from the book as it
    /// is (`generated(for:names:)`), so its title and author are kept there
    /// too. Nothing for a book whose audio is no folder of tracks, or is
    /// only in the cloud, or whose manifest is not one JSON object. Storage
    /// work, off the main thread.
    ///
    /// - Returns: Whether the manifest was written.
    @discardableResult
    static func keepTitleAndAuthor(
        of book: Book,
        title: String?,
        author: String?,
        sessions: BookManifestEditSessions = .shared,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) throws -> Bool {
        try sessions.boundary.perform(.contentAnalysis) { _ in
            let current = sessions.boundary.rebasedToCurrent(book)
            let folder = current.bookFileURL
            guard BookManifestEditing.isTrackFolder(folder, isDataless: isDataless) == true else { return false }
            guard let location = AudioManifestLocation.find(in: folder) else {
                let location = AudioManifestLocation.forNewManifest(in: folder)
                var manifest = generated(for: current, names: try AudioBookParser.trackPaths(in: folder).map(location.name(ofTrackAt:)))
                manifest.title = title ?? manifest.title
                manifest.author = author ?? manifest.author
                try write(manifest, at: location, of: current.id, sessions: sessions)
                return true
            }
            return try change(manifestAt: location, of: current.id, sessions: sessions) { object in
                let keys = AudioManifest.CodingKeys.self
                if let title, object[keys.title.rawValue] as? String != title {
                    object[keys.title.rawValue] = title
                }
                if let author, object[keys.author.rawValue] as? String != author {
                    object[keys.author.rawValue] = author
                }
            }
        }
    }
}

// MARK: - Taking an Edit (FR17)

/// An edit of a book's manifest taken as the book's arrangement: already
/// committed to its record, for the library row and the open readers.
struct BookManifestEdit: Sendable {
    /// The book as its record now records it, with the new analysis.
    let committed: Book
    /// The book's content index, rebuilt from its folder of tracks through
    /// the reader's own parse.
    let index: BookContentIndex
    /// The pauses the edited manifest puts between the book's tracks.
    let pauses: ChapterPauses
    /// A transcribed audiobook's transcript text, laid over the new
    /// arrangement (FR05); nil for a book without one.
    var transcript: TranscriptText? = nil
    /// The book's places this edit moved to their tracks' new chapters,
    /// narrowed to the moves its record took (`MovedPlaces.taken(by:)`);
    /// nil when it moved none.
    var movedPlaces: MovedPlaces? = nil
    /// The title the edited manifest gives, when it gives one that is not
    /// blank; nil leaves the book's.
    let title: String?
    /// The author the edited manifest gives, likewise.
    let author: String?
}

/// What checking a book's manifest for an edit found.
enum BookManifestEditCheck: Sendable {
    /// manifest.json holds what it held: nothing to do.
    case unchanged
    /// The folder, or the manifest, is only in the cloud (FR02): it is left
    /// alone until it is on this Mac.
    case inCloud
    /// manifest.json is gone, or the book's folder is: there is nothing to
    /// take.
    case missing
    /// manifest.json changed but was not taken, with the problem, as an
    /// import says it, and the digest of what it held. The book keeps its
    /// headings.
    case refused(problem: String, digest: String)
    /// The edit is the book's arrangement now.
    case adopted(BookManifestEdit)
}

/// The books whose manifest is being edited in another app, each with the
/// fingerprint of its manifest.json as TextMouth last took or wrote it,
/// shared by everything that checks for an edit (FR17): the watcher of each
/// manifest, and TextMouth becoming the active app.
///
/// Every check runs on one serial queue, as storage work, as Edit Text's
/// checks do (`BookTextEditSessions`), so two checks of a book never
/// overlap, a check waits while a data-directory move or a folder edit holds
/// the storage work, and each sees the baseline the one before it left.
final class BookManifestEditSessions: Sendable {
    /// The sessions of the app's Edit Manifest commands.
    static let shared = BookManifestEditSessions()

    /// One book whose manifest is being edited.
    struct Session: Sendable {
        /// manifest.json as TextMouth last took or wrote it.
        var baseline: FileFingerprint
        /// Hears what each check found, on the checking queue.
        let report: @Sendable (UUID, BookManifestEditCheck) -> Void
    }

    /// The sessions, by book ID, guarded by the lock itself.
    private let sessions = OSAllocatedUnfairLock<[UUID: Session]>(initialState: [:])

    /// The queue every check runs on, one at a time.
    let queue = DispatchQueue(label: "com.textmouth.manifest-edits", qos: .userInitiated)

    /// The boundary checks and writes run inside, as storage work.
    let boundary: StorageBoundary

    /// Sessions checked as storage work of `boundary`: the app's, unless a
    /// test passes its own.
    init(boundary: StorageBoundary = .shared) {
        self.boundary = boundary
    }

    /// Starts, or starts again, the session of the book `bookID`.
    func begin(_ bookID: UUID, _ session: Session) {
        sessions.withLock { $0[bookID] = session }
    }

    /// Ends the session of the book `bookID`, if there is one.
    func end(_ bookID: UUID) {
        _ = sessions.withLock { $0.removeValue(forKey: bookID) }
    }

    /// Whether the book `bookID`'s manifest is being edited.
    func isEditing(_ bookID: UUID) -> Bool {
        sessions.withLock { $0[bookID] != nil }
    }

    /// The books whose manifest is being edited.
    var bookIDs: Set<UUID> {
        sessions.withLock { Set($0.keys) }
    }

    /// The baseline of the book `bookID`, while its manifest is being edited.
    func baseline(of bookID: UUID) -> FileFingerprint? {
        sessions.withLock { $0[bookID]?.baseline }
    }

    /// TextMouth wrote the book `bookID`'s manifest itself, as `written`
    /// describes it (`BookManifestFile.write`): its next check starts from
    /// it. Nothing for a book not being edited.
    func noteWritten(_ bookID: UUID, _ written: FileFingerprint) {
        sessions.withLock { all in
            guard all[bookID] != nil else { return }
            all[bookID]?.baseline = written
        }
    }

    /// Checks `book`, as the library holds it now, for an edit soon, on the
    /// checking queue.
    func scheduleCheck(of book: Book) {
        queue.async { [self] in
            check(book)
        }
    }

    /// Checks `book` for an edit as storage work, with its paths under the
    /// data directory in use, reports what it found to the session, and
    /// keeps the baseline the check leaves. Runs on the queue.
    /// - Returns: What was found; nil for a book not being edited.
    @discardableResult
    private func check(_ book: Book) -> BookManifestEditCheck? {
        let bookID = book.id
        guard let session = sessions.withLock({ $0[bookID] }) else { return nil }
        let found: BookManifestEditCheck = boundary.perform(.contentAnalysis) { _ in
            // The baseline is read again: a check that waited for a hold
            // follows the one before it.
            let baseline = sessions.withLock { $0[bookID]?.baseline } ?? session.baseline
            let checked = Self.check(boundary.rebasedToCurrent(book), against: baseline)
            if let next = checked.baseline {
                sessions.withLock { all in
                    guard all[bookID] != nil else { return }
                    all[bookID]?.baseline = next
                }
            }
            return checked.found
        }
        session.report(bookID, found)
        return found
    }

    /// Checks `book`'s manifest against `baseline`, the manifest as
    /// TextMouth last took or wrote it, and takes an edit found (FR17).
    ///
    /// - A manifest whose bytes are the baseline's is unchanged, whatever
    ///   its stamp says; one only in the cloud is left alone, and nothing
    ///   is downloaded.
    /// - Otherwise it is checked as an import checks one
    ///   (`AudioManifestCheck.checkedManifest(at:audioFolder:)`), against
    ///   the book's own tracks, and a manifest with a problem changes
    ///   nothing: the problem is said in the import's words, and the
    ///   baseline stays, so the user's next save is checked again.
    /// - A manifest that would make the book's tracks into sections, as a
    ///   converted DAISY book's does, is refused too: a manifest arranges
    ///   tracks and adds or removes none.
    /// - A good one rebuilds the book's headings from its folder of tracks
    ///   through the reader's own parse
    ///   (`BookContentAnalysisService.analyzeAudio`), which every track
    ///   must pass, as an import's does, and commits the new index to the
    ///   book's record (`LibraryPersistenceService.saveContentAnalysis`).
    ///
    /// One debug-log line says what was taken or refused, naming the book's
    /// title, never a path. Runs off the main thread, as storage work.
    /// - Returns: What was found, and the baseline from now on when it
    ///   changed.
    static func check(
        _ book: Book,
        against baseline: FileFingerprint,
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> (found: BookManifestEditCheck, baseline: FileFingerprint?) {
        guard !book.tmbDirectoryName.isEmpty else { return (.missing, nil) }
        let folder = book.bookFileURL
        if isDataless(folder) {
            return (.inCloud, nil)
        }
        guard let location = AudioManifestLocation.find(in: folder) else { return (.missing, nil) }
        if isDataless(location.url) {
            return (.inCloud, nil)
        }
        // The manifest is stamped before it is read, so a save while it is
        // read differs from this stamp next time.
        guard let stamp = FileStamp(of: location.url) else { return (.missing, nil) }
        if baseline.comparison(with: stamp) == .same {
            return (.unchanged, nil)
        }
        guard let bytes = try? Data(contentsOf: location.url) else { return (.missing, nil) }
        let digest = hasher.digestOfData(bytes)
        let fingerprint = FileFingerprint(stamp: stamp, digest: digest)
        guard digest != baseline.digest else {
            // Rewritten with the same bytes: nothing was edited.
            return (.unchanged, fingerprint)
        }

        /// Refuses the edit for `problem`, with one line saying so.
        func refuse(_ problem: String) -> (found: BookManifestEditCheck, baseline: FileFingerprint?) {
            DiagnosticLog.event(.storage, "MANIFEST_EDIT_REFUSED: \(book.title): \(problem)")
            return (.refused(problem: problem, digest: digest), nil)
        }

        let manifest: AudioManifest
        do {
            manifest = try AudioManifestCheck.checkedManifest(at: location, audioFolder: folder)
        } catch {
            return refuse(error.localizedDescription)
        }
        guard (manifest.segments ?? []).isEmpty else {
            return refuse(BookManifestEditWording.sectionsGiven)
        }
        let analysis: BookContentAnalysisService.Result
        do {
            analysis = try BookContentAnalysisService.analyzeAudio(book: book, url: folder)
        } catch {
            return refuse(error.localizedDescription)
        }
        // A transcribed audiobook's transcript is laid over the new
        // arrangement, and its layer kept in the index committed.
        let transcript = TranscriptTextLoader.load(for: book, audioIndex: analysis.index)
        let index = transcript.index
        guard index.audioLayout == .multiFile else {
            return refuse(BookManifestEditWording.sectionsGiven)
        }
        // The book's places follow their tracks, committed with the
        // analysis, or not at all.
        let moved = movedPlaces(of: book, to: index, at: Date())
        let committed: Book?
        do {
            committed = try LibraryPersistenceService.saveContentAnalysis(
                for: book,
                index: index,
                cacheFormatVersion: nil,
                movedPlaces: moved
            )
        } catch {
            return refuse(error.localizedDescription)
        }
        guard let committed else {
            // The record could not take it now (it is only in the cloud, or
            // the book moved meanwhile); the next check tries again.
            return refuse(BookTextEditWording.recordUnavailable)
        }
        DiagnosticLog.event(
            .storage,
            "MANIFEST_EDIT_ADOPTED: \(book.title): \(index.chapters.count) track(s), \(index.allHeadings.count) heading(s)"
        )
        if moved != nil {
            DiagnosticLog.event(.storage, "PLACES_MOVED: \(book.title): followed their tracks into the edited manifest's order")
        }
        return (
            .adopted(BookManifestEdit(
                committed: committed,
                index: index,
                pauses: ChapterPauses.betweenTracks(of: index, inAudioFolder: folder),
                transcript: transcript.text,
                // Narrowed to the moves the record took.
                movedPlaces: moved?.taken(by: committed),
                title: manifest.title?.nonBlank,
                author: manifest.author?.nonBlank
            )),
            fingerprint
        )
    }

    /// The moves of `book`'s places (`Book.relocatablePlaces`) from the
    /// arrangement its record holds, which they were saved in, to `index`,
    /// the arrangement the edited manifest gives (`TrackPlaces`); nil when
    /// none moved, or the record holds no index to move them from.
    private static func movedPlaces(of book: Book, to index: BookContentIndex, at date: Date) -> MovedPlaces? {
        guard let old = book.storedBookInfo()?.contentIndex else { return nil }
        let original = book.relocatablePlaces
        let moved = TrackPlaces.moved(original, from: old, to: index, at: date)
        guard moved != original else { return nil }
        return MovedPlaces(bookID: book.id, original: original, moved: moved, snapshot: nil)
    }
}
