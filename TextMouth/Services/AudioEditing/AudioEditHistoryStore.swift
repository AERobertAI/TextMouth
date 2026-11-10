import Foundation

/// Reads and writes a book's audio edit history (FR04, `AudioEditHistory`):
/// edits.json in the package's audioEdits folder (`AudioEditPackage`).
///
/// The file is written whole and replaced atomically, as a package's other
/// records are, readable and with sorted keys. It syncs with the package, and
/// a read never downloads it: one only in the cloud is left there
/// (`Lookup.inCloud`). A file that cannot be read or decoded, as a write cut
/// short on another Mac or a hand edit can leave it, is preserved beside
/// itself (`SavedFile.preserveUnusable`) with one AUDIO_EDITS_FILE line in
/// the debug log, and reported unusable; nothing replaces it until the
/// editor starts the book's history over.
///
/// A recording's original take is recorded by its origin record,
/// origin.json, as the Record window saved it (`BookOrigin.OriginalTake`),
/// until the recording is first edited. A read of a package without
/// edits.json takes the take from there, so callers always see one history;
/// a write keeps the take in origin.json for as long as the history holds
/// nothing else, and otherwise writes edits.json and strikes the take from
/// origin.json, so exactly one record describes it at any time.
///
/// Every change goes through `update`, which reads, changes, and writes the
/// history under one lock for the whole process, so the editor, a render,
/// and the original policy's sweep never write over one another's changes.
/// Call it off the main thread: it reads and writes files.
enum AudioEditHistoryStore {
    /// Where a read found the history.
    enum Source: Equatable, Sendable {
        /// Nowhere: the book's audio was never edited, and it holds no
        /// recording's take.
        case noRecord
        /// edits.json.
        case editsFile
        /// A recording's origin record, holding its take, as the Record window
        /// saved it.
        case recordingOrigin(BookOrigin)
    }

    /// What one read of a package's history found.
    enum Lookup: Equatable {
        /// The history, and where it was found; an empty history when the
        /// package has none.
        case found(AudioEditHistory, Source)
        /// The history, or the origin record that holds a recording's take,
        /// is only in the cloud, so it was not read: reading it would have
        /// downloaded it first.
        case inCloud
        /// A history of a layout this TextMouth does not read, as a later
        /// version on another Mac can write: it is left as it is.
        case unsupportedVersion(Int)
        /// A history that cannot be used, for the reason given; it was
        /// preserved beside itself.
        case unusable(String)
    }

    /// The tag of the debug log's line about a history that cannot be used,
    /// as TRANSCRIPT_FILE is for a transcript.
    static let logTag = "AUDIO_EDITS_FILE"

    /// Serializes every read-change-write of any package's history, so no
    /// two changes interleave. Held only by `update`, which never nests.
    private static let lock = NSLock()

    /// How edits.json is written: readable, since it is small and people
    /// recovering a book may read it, with sorted keys, so one history is
    /// always written as the same bytes, and with ISO 8601 dates, as
    /// bookInfo.json writes its own.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// How edits.json is read.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Reading

    /// The history of the package at `package`, whose book's file is
    /// `bookFile` (its path inside the package: the file of a book of one,
    /// which is the one a recording's take belongs to). edits.json is read
    /// through `reader`, which leaves files only in the cloud there, and the
    /// origin record through `loadOrigin`, which throws only for one there;
    /// tests pass readers that refuse as such files do.
    static func read(
        fromPackage package: URL,
        bookFile: String,
        using reader: SavedFile.Reader = SavedFile.readWithoutDownloading,
        loadOrigin: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:)
    ) -> Lookup {
        let url = AudioEditPackage.historyURL(in: package)
        switch SavedFile.read(url, using: reader) {
        case .inCloud:
            return .inCloud
        case .unreadable(let reason):
            preserveUnusable(url, bytes: nil, because: reason)
            return .unusable(reason)
        case .contents(let bytes):
            return lookup(decoding: bytes, at: url)
        case .missing:
            let origin: BookOrigin?
            do {
                origin = try loadOrigin(package)
            } catch {
                // Only a record in the cloud throws: never downloaded here.
                return .inCloud
            }
            guard let origin, let take = origin.originalTake else {
                return .found(AudioEditHistory(), .noRecord)
            }
            return .found(adopting(take, of: bookFile), .recordingOrigin(origin))
        }
    }

    /// What the bytes `bytes`, read from the history at `url`, hold: a
    /// history of the supported layout, a history of another layout, or,
    /// preserved first, an unusable one.
    private static func lookup(decoding bytes: Data, at url: URL) -> Lookup {
        // The layout is read on its own first, so a history a later
        // TextMouth wrote is recognized however the rest of it is laid out.
        if let version = try? decoder.decode(LayoutProbe.self, from: bytes).version,
           version != AudioEditHistory.currentVersion {
            guard version > 0 else {
                let reason = "version \(version) is not a layout any TextMouth writes"
                preserveUnusable(url, bytes: bytes, because: reason)
                return .unusable(reason)
            }
            return .unsupportedVersion(version)
        }
        do {
            return .found(try decoder.decode(AudioEditHistory.self, from: bytes), .editsFile)
        } catch {
            // Described as a transcript's decoding errors are: by kind and
            // place, never quoting the file, which can hold chapter titles.
            let reason = TranscriptStore.describe(error)
            preserveUnusable(url, bytes: bytes, because: reason)
            return .unusable(reason)
        }
    }

    /// The layout version alone, which every layout of edits.json keeps
    /// under the same key.
    private struct LayoutProbe: Decodable {
        let version: Int
    }

    /// A history holding a recording's original take, as its origin record
    /// holds it: the take as the original of the book's file `bookFile`, and
    /// its policy as the book's own.
    private static func adopting(_ take: BookOrigin.OriginalTake, of bookFile: String) -> AudioEditHistory {
        AudioEditHistory(
            policyOverride: take.policyOverride,
            files: [AudioEditList(
                audioFile: bookFile,
                original: AudioOriginal(file: take.fileName, lastEditedAt: take.lastEditedAt)
            )]
        )
    }

    // MARK: Writing

    /// Writes `history`, read from `source`, into the package at `package`,
    /// whose book's file is `bookFile`. A recording whose history holds no
    /// more than its take keeps it in its origin record; otherwise edits.json
    /// is written, replacing any there atomically, and the origin record, if
    /// it still holds the take, no longer does.
    static func write(
        _ history: AudioEditHistory,
        source: Source,
        toPackage package: URL,
        bookFile: String,
        loadOrigin: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:)
    ) throws {
        if case .recordingOrigin(var origin) = source,
           case .take(let take) = originRecord(of: history, bookFile: bookFile) {
            origin.originalTake = take
            try origin.save(toPackage: package)
            return
        }
        try FileManager.default.createDirectory(at: AudioEditPackage.folder(in: package), withIntermediateDirectories: true)
        try encoder.encode(history).write(to: AudioEditPackage.historyURL(in: package), options: .atomic)
        // The origin record is read again rather than taken from `source`, so
        // a take left in it by a write cut short before is struck too.
        if var origin = try? loadOrigin(package), origin.originalTake != nil {
            origin.originalTake = nil
            try origin.save(toPackage: package)
        }
    }

    /// What a recording's origin record would hold for a history.
    private enum OriginRecord {
        /// The take, or nil when it is gone: the history holds nothing more.
        case take(BookOrigin.OriginalTake?)
        /// The history holds more than an origin record can: it needs
        /// edits.json.
        case needsEditsFile
    }

    /// What a recording's origin record can hold of `history`, whose
    /// recording's file is `bookFile`: all of it while there is no edit, no
    /// marker, and no render of that file, no other file, and a policy of
    /// the book's own only beside a take kept at the package root, as the
    /// Record window keeps it.
    private static func originRecord(of history: AudioEditHistory, bookFile: String) -> OriginRecord {
        // An origin record describes one file, the recording's, unedited
        // and without markers, which it has no place for.
        guard history.files.count <= 1 else { return .needsEditsFile }
        let list = history.files.first
        if let list, list.audioFile != bookFile || !list.entries.isEmpty || list.lastRenderedAt != nil || !list.markers.isEmpty {
            return .needsEditsFile
        }
        guard let original = list?.original else {
            // It can say the take is gone, but it keeps a policy only with a take.
            return history.policyOverride == nil ? .take(nil) : .needsEditsFile
        }
        guard BookOrigin.isPlainFileName(original.file) else { return .needsEditsFile }
        return .take(BookOrigin.OriginalTake(
            fileName: original.file,
            lastEditedAt: original.lastEditedAt,
            policyOverride: history.policyOverride
        ))
    }

    // MARK: Changing

    /// Reads the history of the package at `package` (whose book's file is
    /// `bookFile`), lets `change` change it, and writes it back when it
    /// changed, all under the store's lock; then deletes the takes no edit
    /// can use any more. Returns what `change` returns.
    ///
    /// With `startingOver`, a history that cannot be used, already preserved
    /// beside itself, is replaced by an empty one; otherwise it throws.
    /// - Throws: `AudioEditError.historyInCloud`, `.historyFromNewerVersion`,
    ///   or `.historyUnusable` when the history cannot be read; whatever
    ///   `change` throws, writing nothing; or the write's error.
    static func update<Result>(
        package: URL,
        bookFile: String,
        startingOver: Bool = false,
        using reader: SavedFile.Reader = SavedFile.readWithoutDownloading,
        loadOrigin: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:),
        _ change: (inout AudioEditHistory) throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let lookup = read(fromPackage: package, bookFile: bookFile, using: reader, loadOrigin: loadOrigin)
        var (history, source) = try readable(lookup, startingOver: startingOver)
        let before = history
        let result = try change(&history)
        // A history started over is written even unchanged, so the damaged
        // file, already preserved, is replaced and not read again.
        var startedOver = false
        if case .unusable = lookup { startedOver = true }
        if history != before || startedOver {
            try write(history, source: source, toPackage: package, bookFile: bookFile, loadOrigin: loadOrigin)
        }
        if startedOver {
            // The podcast chapters set aside for the old history's original
            // fit no audio the new history will start from, so undoing every
            // edit of the new history must never bring them back.
            AudioEditPackage.discardSetAsidePodcastChapters(inPackage: package)
        }
        AudioEditPackage.removeUnusedTakes(of: history, inPackage: package)
        return result
    }

    /// The history `lookup` found, and where, or the error saying why there
    /// is none to change.
    private static func readable(_ lookup: Lookup, startingOver: Bool) throws -> (AudioEditHistory, Source) {
        switch lookup {
        case .found(let history, let source):
            return (history, source)
        case .inCloud:
            throw AudioEditError.historyInCloud
        case .unsupportedVersion(let version):
            throw AudioEditError.historyFromNewerVersion(version)
        case .unusable(let reason):
            guard startingOver else { throw AudioEditError.historyUnusable(reason) }
            return (AudioEditHistory(), .editsFile)
        }
    }

    // MARK: Damage

    /// Keeps a copy of the unusable history at `url`, holding `bytes` when
    /// they could be read, and writes the one AUDIO_EDITS_FILE line that
    /// says so.
    private static func preserveUnusable(_ url: URL, bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: logTag,
            in: .storage,
            standIn: "the book's audio can't be edited until its history is started over"
        )
    }
}
