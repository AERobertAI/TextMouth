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
        guard mayHaveTrackFolder(book) else { return false }
        return isTrackFolder(book.bookFileURL, isDataless: isDataless) == true
    }

    /// Whether `book` could play a folder of tracks whose manifest can be
    /// edited, as its row tells without looking at the disk: a book
    /// `canEditManifest(of:isTrackFolder:)` offers whatever its audio, whose
    /// audio folder is inside its package.
    static func mayHaveTrackFolder(_ book: Book) -> Bool {
        canEditManifest(of: book, isTrackFolder: true) && book.filePath.hasPrefix(book.tmbDirectory.path + "/")
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
        of bookID: UUID?,
        sessions: BookManifestEditSessions = .shared,
        hasher: FingerprintHasher = .md5
    ) throws {
        try data.write(to: location.url, options: .atomic)
        if let bookID, let stamp = FileStamp(of: location.url) {
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
        of bookID: UUID?,
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

    /// Renames the track `old` to `new`, both as the manifest spells them,
    /// everywhere `object`, a manifest's JSON object, names it: an entry of
    /// tracks (a name alone, or an object's file), order, a key of chapters,
    /// and the file of a section or of one of its clips.
    static func renameTrack(_ old: String, to new: String, in object: inout [String: Any]) {
        /// `value` renamed when it names the track.
        func renamed(_ value: Any) -> Any {
            (value as? String) == old ? new : value
        }
        /// `value`, an object whose file may name the track, renamed.
        func renamedFile(_ value: Any) -> Any {
            guard var entry = value as? [String: Any] else { return renamed(value) }
            if let file = entry["file"] {
                entry["file"] = renamed(file)
            }
            if let clips = entry["clips"] as? [Any] {
                entry["clips"] = clips.map(renamedFile)
            }
            return entry
        }
        let keys = AudioManifest.CodingKeys.self
        if let tracks = object[keys.tracks.rawValue] as? [Any] {
            object[keys.tracks.rawValue] = tracks.map(renamedFile)
        }
        if let order = object[keys.order.rawValue] as? [Any] {
            object[keys.order.rawValue] = order.map(renamed)
        }
        if var chapters = object[keys.chapters.rawValue] as? [String: Any], let title = chapters.removeValue(forKey: old) {
            chapters[new] = title
            object[keys.chapters.rawValue] = chapters
        }
        if let segments = object[keys.segments.rawValue] as? [Any] {
            object[keys.segments.rawValue] = segments.map(renamedFile)
        }
    }

    /// Keeps `title` and `author` in the manifest of `book`'s folder of
    /// tracks, nil leaving either as the manifest has it: the manifest's
    /// side of the one write of a manifest book's title and author
    /// (`LibraryViewModel.setTitleAndAuthor(ofManifestBook:title:author:)`).
    /// A book without a manifest is given one first, from the book as it
    /// is (`generated(for:names:)`), so its title and author are kept there
    /// too. Nothing for a book whose audio is no folder of tracks, or is
    /// only in the cloud, or whose manifest is not one JSON object: the
    /// caller keeps the edit owed then (`ManifestOwedFields`,
    /// `BookManifestEditSessions.settleOwedFields(of:adding:isDataless:)`),
    /// so it is written once the manifest can take it. Storage work, off the
    /// main thread.
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

    /// Whether the manifest of `book`'s folder of tracks holds the row's
    /// values of `fields` (only the title and the author are told): its
    /// `title` and `author` strings equal the row's. Also true when the
    /// book's audio is no longer a folder of tracks whose manifest TextMouth
    /// keeps, since nothing can be owed there. False when the folder or the
    /// manifest is only in the cloud, when there is no manifest, and when the
    /// manifest cannot be read or is not one JSON object. A read that
    /// downloads nothing. Storage work, off the main thread.
    static func holds(
        _ fields: Set<Book.MetadataField>,
        of book: Book,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Bool {
        let folder = book.bookFileURL
        switch BookManifestEditing.isTrackFolder(folder, isDataless: isDataless) {
        case nil:
            return false
        case false?:
            return true
        case true?:
            break
        }
        guard let location = AudioManifestLocation.find(in: folder), !isDataless(location.url) else { return false }
        // Read with downloading switched off, so a manifest that went to the
        // cloud meanwhile refuses the read rather than download.
        guard let data = try? DatalessFiles.withoutDownloading({ try Data(contentsOf: location.url) }),
              let object = (try? JSONSerialization.jsonObject(with: AudioManifest.withoutByteOrderMark(data))) as? [String: Any]
        else { return false }
        let keys = AudioManifest.CodingKeys.self
        let held = [
            (Book.MetadataField.title, keys.title.rawValue, book.title),
            (Book.MetadataField.author, keys.author.rawValue, book.author)
        ]
        return held.allSatisfy { field, key, value in
            !fields.contains(field) || object[key] as? String == value
        }
    }

    // MARK: Hand Edits Made Before FR17

    /// What keeping a book's hand-edited title and author in its manifest
    /// did (`keepHandEditedTitleAndAuthor(of:sessions:isDataless:)`).
    enum HandEditKeeping: Equatable, Sendable {
        /// The manifest was given the row's title, its author, or both.
        case kept
        /// Nothing to write: no field edited by hand, no manifest, or a
        /// manifest that gives no other title or author.
        case unchanged
        /// The folder or the manifest is only in the cloud, or the manifest
        /// could not be written: the book waits for a later launch.
        case waiting
    }

    /// Writes into `book`'s manifest the title and the author its row
    /// records as edited by hand (`Book.handEdits`), each only where the
    /// manifest gives another that is not blank, through
    /// `change(manifestAt:of:sessions:_:)`, the one write of a manifest.
    ///
    /// Since FR17 a hand edit of a book of tracks' title or author is
    /// written into its manifest at once, so a row and a manifest that
    /// disagree about a field edited by hand can only hold an edit made
    /// before FR17, which the manifest would otherwise win once an edit
    /// made outside a session is taken (FR18). The one-time pass at launch
    /// keeps each such edit (`LibraryViewModel.keepHandEditedTitlesInManifestsOnce`),
    /// and every look does too until the pass is recorded as done
    /// (`BookManifestEditSessions.keepsHandEditsFirst`). Downloads nothing.
    /// Storage work, off the main thread, on the manifest sessions' queue.
    static func keepHandEditedTitleAndAuthor(
        of book: Book,
        sessions: BookManifestEditSessions = .shared,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> HandEditKeeping {
        sessions.boundary.perform(.contentAnalysis) { _ in
            let current = sessions.boundary.rebasedToCurrent(book)
            let title = current.handEdits?.contains(.title) == true ? current.title : nil
            let author = current.handEdits?.contains(.author) == true ? current.author : nil
            guard title != nil || author != nil, BookManifestEditing.mayHaveTrackFolder(current) else { return .unchanged }
            let folder = current.bookFileURL
            guard !isDataless(folder) else { return .waiting }
            guard let location = AudioManifestLocation.find(in: folder) else { return .unchanged }
            guard !isDataless(location.url) else { return .waiting }
            do {
                let written = try DatalessFiles.withoutDownloading {
                    try change(manifestAt: location, of: current.id, sessions: sessions) { object in
                        let keys = AudioManifest.CodingKeys.self
                        keep(title, at: keys.title.rawValue, in: &object)
                        keep(author, at: keys.author.rawValue, in: &object)
                    }
                }
                return written ? .kept : .unchanged
            } catch {
                if !DatalessFiles.isDownloadRefusal(error) {
                    DiagnosticLog.event(.storage, "MANIFEST_NOT_WRITTEN: \(current.title): \(error.localizedDescription)")
                }
                return .waiting
            }
        }
    }

    /// Gives `key` of `object`, a manifest's JSON object, the row's
    /// `value`, where the manifest gives another that is not blank.
    private static func keep(_ value: String?, at key: String, in object: inout [String: Any]) {
        guard let value, let theirs = (object[key] as? String)?.nonBlank, theirs != value else { return }
        object[key] = value
    }
}

// MARK: - Fields a Manifest Is Owed (FR17)

/// The title and the author of the audiobooks of tracks that a write could
/// not put into the manifest yet (the manifest was only in the cloud, or the
/// user was midway through an edit of it), kept on this Mac across a quit:
/// per book, the fields whose row value the manifest is owed.
///
/// While a field is owed, the manifest's value for it is neither compared nor
/// adopted: the row's value stands, so a look never takes a stale manifest
/// title over the user's retitle. The owed fields are written at every look
/// before it compares, and are no longer owed once the manifest holds the
/// row's values (`BookManifestEditSessions.settleOwedFields(of:adding:isDataless:)`).
///
/// The record holds nothing but book IDs and field names, never a title. It
/// is only changed on the manifest sessions' queue, so no two changes
/// overlap. One record serves every library, since book IDs are unique.
///
/// `@unchecked Sendable`: its one stored property is a constant, and
/// `UserDefaults` is documented thread-safe.
struct ManifestOwedFields: @unchecked Sendable {
    /// The preference the record is kept under: book ID string to the owed
    /// fields' raw values.
    static let key = "manifestOwedFields"

    /// The fields that can be owed: the two a manifest keeps.
    static let owable: Set<Book.MetadataField> = [.title, .author]

    /// Where the record is kept.
    let preferences: UserDefaults

    init(preferences: UserDefaults = TextMouthRuntime.current.preferences) {
        self.preferences = preferences
    }

    /// The whole record; empty when nothing is stored or the stored value is
    /// not the dictionary of string lists it should be.
    private var stored: [String: [String]] {
        preferences.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    /// The fields the manifest of the book `bookID` is owed. Only the title
    /// and the author are ever read back; any other stored name is ignored.
    func owed(by bookID: UUID) -> Set<Book.MetadataField> {
        let names = stored[bookID.uuidString] ?? []
        return Set(names.compactMap(Book.MetadataField.init(rawValue:))).intersection(Self.owable)
    }

    /// Records `fields` as the ones the manifest of the book `bookID` is
    /// owed, replacing what was recorded for it. An empty set removes the
    /// book's entry, and the whole record is removed when no book is left.
    /// Fields other than the title and the author are not stored.
    func setOwed(_ fields: Set<Book.MetadataField>, by bookID: UUID) {
        var record = stored
        let names = Book.MetadataField.ordered(fields.intersection(Self.owable)).map(\.rawValue)
        record[bookID.uuidString] = names.isEmpty ? nil : names
        if record.isEmpty {
            preferences.removeObject(forKey: Self.key)
        } else {
            preferences.set(record, forKey: Self.key)
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
    /// blank; nil leaves the book's. Always nil while the manifest is owed
    /// the row's title (`ManifestOwedFields`): the row's stands.
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

    /// The title and author the manifests are owed (`ManifestOwedFields`),
    /// only changed on `queue`.
    let owed: ManifestOwedFields

    /// Sessions checked as storage work of `boundary`: the app's, unless a
    /// test passes its own, and keeping what manifests are owed in `owed`.
    init(boundary: StorageBoundary = .shared, owed: ManifestOwedFields = ManifestOwedFields()) {
        self.boundary = boundary
        self.owed = owed
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
            let checked = Self.check(boundary.rebasedToCurrent(book), against: baseline, owed: owed.owed(by: bookID))
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
    /// A field the manifest is owed (`owed`) is not adopted: the edit taken
    /// gives no title, or no author, for it.
    ///
    /// One debug-log line says what was taken or refused, naming the book's
    /// title, never a path. Runs off the main thread, as storage work.
    /// - Returns: What was found, and the baseline from now on when it
    ///   changed.
    static func check(
        _ book: Book,
        against baseline: FileFingerprint,
        owed: Set<Book.MetadataField> = [],
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
        let found = take(book, manifestAt: location, digest: digest, owed: owed)
        // Only a taken edit is the baseline from now on: a refused one
        // keeps the old, so the user's next save is checked again.
        guard case .adopted = found else { return (found, nil) }
        return (found, fingerprint)
    }

    // MARK: Edits Made Outside a Session (FR18)

    /// Looks at `book`'s manifest for an edit made outside Edit Manifest, in
    /// an editor opened from Finder, on another Mac, or while TextMouth was
    /// closed (FR18), and takes one found exactly as a session's check takes
    /// a save (`take(_:manifestAt:digest:)`). The user, October 14, 2026:
    /// "Would it work if I found the manafest in Finder and edited it
    /// outside Text Mouth? ... I think ither way should work".
    ///
    /// The manifest is compared with the book, never with a date or a
    /// remembered fingerprint, so an edit made anywhere is found and a
    /// manifest that matches its book is left alone, read and nothing more
    /// (`manifest(_:at:arranges:as:tracks:showingPauses:)`). Only an
    /// audiobook of tracks is looked at: one its record holds as a folder of
    /// tracks played one per heading, so a manifest edited to give sections
    /// is refused, as a session refuses it, and a converted DAISY book is
    /// passed over. Nothing is downloaded (FR02): a book whose record,
    /// folder, manifest, or any track is only in the cloud is left as it is.
    /// The look reads only the record, the small manifest, and the audio
    /// folder's listing; only a take reads the tracks. Runs off the main
    /// thread, as storage work.
    ///
    /// - Parameters:
    ///   - pauses: The pauses an open reader keeps between the book's
    ///     tracks, compared with the manifest's too; nil for a book no
    ///     reader shows yet, whose load reads its pauses afresh.
    ///   - owed: The fields the manifest is owed (`ManifestOwedFields`): the
    ///     row's value stands for each, so the manifest's is neither compared
    ///     nor adopted.
    ///   - isDataless: Tells a file only in the cloud; tests stand in for it.
    static func look(
        at book: Book,
        showingPauses pauses: ChapterPauses? = nil,
        owed: Set<Book.MetadataField> = [],
        hasher: FingerprintHasher = .md5,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> BookManifestEditCheck {
        guard BookManifestEditing.mayHaveTrackFolder(book) else { return .missing }
        let folder = book.bookFileURL
        guard !isDataless(folder) else { return .inCloud }
        guard let location = AudioManifestLocation.find(in: folder) else { return .missing }
        guard !isDataless(location.url) else { return .inCloud }
        // Read with downloading switched off, so a file that went to the
        // cloud meanwhile refuses the read rather than download.
        let read: (record: BookInfo, bytes: Data, tracks: [String])
        do {
            read = try DatalessFiles.withoutDownloading {
                (try BookInfo.load(from: book.tmbDirectory), try Data(contentsOf: location.url), try AudioBookParser.trackPaths(in: folder))
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .inCloud
        } catch {
            // No record, manifest, or folder to compare: a book without a
            // record builds its index from the manifest as it loads.
            return .missing
        }
        guard let shown = read.record.contentIndex, shown.audioLayout == .multiFile else { return .missing }
        if manifest(read.bytes, at: location, arranges: book, as: shown, tracks: read.tracks, showingPauses: pauses, owed: owed) {
            return .unchanged
        }
        // The take reads every track, so it waits until all are on this Mac.
        guard !read.tracks.contains(where: { isDataless(folder.appendingPathComponent($0)) }) else { return .inCloud }
        return take(book, manifestAt: location, digest: hasher.digestOfData(read.bytes), owed: owed)
    }

    /// Whether the manifest `bytes`, at `location` in the audio folder whose
    /// tracks are `paths` (`AudioBookParser.trackPaths(in:)`), arranges
    /// `book` as it shows, `shown` being the index its record holds (FR18):
    /// the tracks in the same order, with the same titles, and the same group
    /// headings at the same levels, the manifest read as every load of the
    /// book reads it (`AudioTrackPlan`, `AudioBookParser.headings(of:chapterIndex:)`);
    /// the title and the author the manifest gives, if any, the book's, each
    /// left out that is in `owed` (the fields the manifest is owed, whose
    /// row value stands); and,
    /// given `pauses`, the pauses an open reader keeps, the ones the manifest
    /// puts between the tracks (`ChapterPauses.betweenTracks(of:inAudioFolder:)`).
    ///
    /// A manifest that cannot be decoded matches no book: TextMouth writes
    /// none such and an import takes none, so one in a book's package is a
    /// mistake made since, which the take refuses in the import's words. A
    /// manifest giving sections matches no book of tracks either.
    static func manifest(
        _ bytes: Data,
        at location: AudioManifestLocation,
        arranges book: Book,
        as shown: BookContentIndex,
        tracks paths: [String],
        showingPauses pauses: ChapterPauses?,
        owed: Set<Book.MetadataField> = []
    ) -> Bool {
        guard let manifest = try? AudioManifest.decoded(from: bytes), (manifest.segments ?? []).isEmpty else { return false }
        let plan = AudioTrackPlan(arranging: paths.map(location.name(ofTrackAt:)), by: manifest)
        let trackPaths = plan.tracks.map { location.path(ofTrackNamed: $0.name) }
        let headings = plan.tracks.enumerated().flatMap { AudioBookParser.headings(of: $1, chapterIndex: $0) }
        let shownHeadings = shown.allHeadings
        guard shown.chapters.map(\.audioFilePath) == trackPaths.map(Optional.some),
              headings.map(\.text) == shownHeadings.map(\.text),
              headings.map(\.level) == shownHeadings.map(\.level),
              headings.map(\.chapterIndex) == shownHeadings.map(\.chapterIndex)
        else { return false }
        if !owed.contains(.title), let title = manifest.title?.nonBlank, title != book.title {
            return false
        }
        if !owed.contains(.author), let author = manifest.author?.nonBlank, author != book.author {
            return false
        }
        if let pauses, pauses != ChapterPauses.betweenTracks(of: shown, inAudioFolder: book.bookFileURL) {
            return false
        }
        return true
    }

    /// Looks at `book`'s manifest for an edit made outside a session
    /// (`look(at:showingPauses:hasher:isDataless:)`) now, on the checking
    /// queue, so it never overlaps a check or a write of the manifest, as
    /// storage work with its paths under the data directory in use, and
    /// waits for it: for a caller off the main thread, as a reader's load
    /// and the launch's look are (FR18). A book being edited in a session is
    /// left to its session, whose checks take the same edits.
    func look(at book: Book, showingPauses pauses: ChapterPauses? = nil, isDataless: (URL) -> Bool = DatalessFiles.isDataless) -> BookManifestEditCheck {
        queue.sync {
            lookOnQueue(at: book, showingPauses: pauses, isDataless: isDataless)
        }
    }

    /// Looks as `look(at:showingPauses:isDataless:)` does, soon, without
    /// waiting, and hands what was found to `report` on the checking queue:
    /// for the main thread, as TextMouth becoming active looks (FR18).
    func scheduleLook(at book: Book, showingPauses pauses: ChapterPauses?, report: @escaping @Sendable (BookManifestEditCheck) -> Void) {
        queue.async { [self] in
            report(lookOnQueue(at: book, showingPauses: pauses, isDataless: DatalessFiles.isDataless))
        }
    }

    /// Whether each look first keeps the book's hand-edited title and
    /// author in its manifest (`BookManifestFile.keepHandEditedTitleAndAuthor`):
    /// from launch until the one-time pass that does so for every book is
    /// recorded as done, so a look made before the pass reaches a book, or
    /// at a book the pass left waiting in the cloud, never takes the
    /// manifest's title over an edit made before FR17. Guarded by the lock.
    private let keepsHandEditsFirst = OSAllocatedUnfairLock(initialState: false)

    /// Sets whether each look first keeps the book's hand-edited title and
    /// author in its manifest.
    func setKeepsHandEditsFirst(_ keeps: Bool) {
        keepsHandEditsFirst.withLock { $0 = keeps }
    }

    /// The look of `look(at:showingPauses:isDataless:)`, on the queue.
    private func lookOnQueue(at book: Book, showingPauses pauses: ChapterPauses?, isDataless: (URL) -> Bool) -> BookManifestEditCheck {
        guard !isEditing(book.id) else { return .unchanged }
        if keepsHandEditsFirst.withLock({ $0 }) {
            _ = BookManifestFile.keepHandEditedTitleAndAuthor(of: book, sessions: self, isDataless: isDataless)
        }
        // What the manifest is owed is written before the look compares, so
        // the look finds the manifest holding the row's title and author.
        settleOwedFields(of: book, isDataless: isDataless)
        return boundary.perform(.contentAnalysis) { _ in
            // Read after the settle, so a field just written is not owed.
            Self.look(at: boundary.rebasedToCurrent(book), showingPauses: pauses, owed: owed.owed(by: book.id), isDataless: isDataless)
        }
    }

    // MARK: Fields Owed to a Manifest (FR17)

    /// Writes into `book`'s manifest the row's current title and author,
    /// whichever the manifest is owed (`owed`) or is owed by this edit
    /// (`fields`), and records what it is still owed: nothing once the
    /// manifest holds the row's values (`BookManifestFile.holds(_:of:isDataless:)`),
    /// which is also so for a book whose audio is no folder of tracks. A
    /// write that fails is logged as `MANIFEST_NOT_WRITTEN`, a refusal to
    /// download aside, and leaves the fields owed. Storage work: call it
    /// only on `queue`, the one place the record is changed.
    ///
    /// - Parameters:
    ///   - book: The book, whose title and author are the row's now.
    ///   - fields: Fields an edit just changed, owed from now on even if this
    ///     write cannot put them in the manifest.
    ///   - isDataless: Tells a file only in the cloud; tests stand in for it.
    /// - Returns: Whether the manifest was written.
    @discardableResult
    func settleOwedFields(
        of book: Book,
        adding fields: Set<Book.MetadataField> = [],
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Bool {
        boundary.perform(.contentAnalysis) { _ in
            let current = boundary.rebasedToCurrent(book)
            let owedNow = owed.owed(by: book.id).union(fields).intersection(ManifestOwedFields.owable)
            guard !owedNow.isEmpty else { return false }
            var didWrite = false
            do {
                didWrite = try BookManifestFile.keepTitleAndAuthor(
                    of: current,
                    title: owedNow.contains(.title) ? current.title : nil,
                    author: owedNow.contains(.author) ? current.author : nil,
                    sessions: self,
                    isDataless: isDataless
                )
            } catch {
                if !DatalessFiles.isDownloadRefusal(error) {
                    DiagnosticLog.event(.storage, "MANIFEST_NOT_WRITTEN: \(current.title): \(error.localizedDescription)")
                }
            }
            owed.setOwed(BookManifestFile.holds(owedNow, of: current, isDataless: isDataless) ? [] : owedNow, by: book.id)
            return didWrite
        }
    }

    // MARK: The Take (FR17)

    /// Takes the manifest at `location`, whose bytes have the digest
    /// `digest`, as `book`'s arrangement: the one take of an edited
    /// manifest, whether a session's check found the edit (FR17) or a look
    /// found the manifest arranging the book otherwise than it shows (FR18,
    /// `look(at:showingPauses:hasher:isDataless:)`). It checks the manifest as an
    /// import does, rebuilds the book's headings through the reader's own
    /// parse, moves the book's places to their tracks, and commits all of it
    /// to the book's record, or refuses it, changing nothing, with the
    /// problem in the import's words (see `check(_:against:owed:hasher:isDataless:)`).
    /// A title or author the manifest is owed (`owed`) is not adopted.
    /// Reads every track: runs off the main thread, as storage work.
    private static func take(
        _ book: Book,
        manifestAt location: AudioManifestLocation,
        digest: String,
        owed: Set<Book.MetadataField>
    ) -> BookManifestEditCheck {
        let folder = book.bookFileURL

        /// Refuses the edit for `problem`, with one line saying so.
        func refuse(_ problem: String) -> BookManifestEditCheck {
            DiagnosticLog.event(.storage, "MANIFEST_EDIT_REFUSED: \(book.title): \(problem)")
            return .refused(problem: problem, digest: digest)
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
        return .adopted(BookManifestEdit(
            committed: committed,
            index: index,
            pauses: ChapterPauses.betweenTracks(of: index, inAudioFolder: folder),
            transcript: transcript.text,
            // Narrowed to the moves the record took.
            movedPlaces: moved?.taken(by: committed),
            // A field the manifest is owed keeps the row's value.
            title: owed.contains(.title) ? nil : manifest.title?.nonBlank,
            author: owed.contains(.author) ? nil : manifest.author?.nonBlank
        ))
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
