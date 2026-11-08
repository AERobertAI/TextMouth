import Foundation

/// Reads and writes a transcribed audiobook's transcript, transcript.json
/// in its package (FR05, `Transcript`).
///
/// The file is written whole and replaced atomically, as a package's other
/// records are, compact with sorted keys, so one transcript is always
/// written as the same bytes. It syncs with the package, so another Mac
/// sharing the library reads it too, and a read never downloads it: one
/// only in the cloud is left there (`Lookup.inCloud`). A file that cannot
/// be read or decoded, or holds a transcript that fails validation, as a
/// write cut short on another Mac or a hand edit can leave it, is preserved
/// beside itself (`SavedFile.preserveUnusable`) and ignored, with one
/// TRANSCRIPT_FILE line in the debug log; the book then shows no transcript
/// text until it is transcribed again, which replaces the file.
enum TranscriptStore {
    /// What one read of a package's transcript found.
    enum Lookup: Equatable {
        /// The package holds no transcript.
        case missing
        /// The transcript is only in the cloud, so it was not read: reading
        /// it would have downloaded it first.
        case inCloud
        /// The transcript, decoded and valid.
        case found(Transcript)
        /// A transcript of a layout this TextMouth does not read, as a later
        /// version on another Mac can write: it is left as it is, neither
        /// preserved nor read.
        case unsupportedVersion(Int)
        /// A transcript that cannot be used, for the reason given; it was
        /// preserved beside itself.
        case unusable(String)
    }

    /// The tag of the debug log's line about a transcript that cannot be
    /// used, as READING_STATS_FILE and SUBSTITUTIONS_FILE are for theirs.
    static let logTag = "TRANSCRIPT_FILE"

    /// How transcript.json is written: compact, since a long book's
    /// transcript runs to megabytes and only TextMouth reads it, with sorted
    /// keys, so one transcript is always written as the same bytes, and
    /// with ISO 8601 dates, as bookInfo.json writes its own.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// How transcript.json is read.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Reading

    /// The transcript in the package at `tmbDir`, read through `reader`:
    /// the app's leaves files only in the cloud there
    /// (`SavedFile.readWithoutDownloading`), and tests pass one that
    /// refuses as such a file does.
    static func read(
        from tmbDir: URL,
        using reader: SavedFile.Reader = SavedFile.readWithoutDownloading
    ) -> Lookup {
        let url = TextMouthPaths.transcriptPath(in: tmbDir)
        switch SavedFile.read(url, using: reader) {
        case .missing:
            return .missing
        case .inCloud:
            return .inCloud
        case .unreadable(let reason):
            preserveUnusable(url, bytes: nil, because: reason)
            return .unusable(reason)
        case .contents(let bytes):
            return lookup(decoding: bytes, at: url)
        }
    }

    /// What the bytes `bytes`, read from the transcript at `url`, hold:
    /// a transcript of the supported layout that passes validation, a
    /// transcript of another layout, or, preserved first, an unusable one.
    private static func lookup(decoding bytes: Data, at url: URL) -> Lookup {
        // The layout is read on its own first, so a transcript a later
        // TextMouth wrote is recognized however the rest of it is laid out.
        if let version = try? decoder.decode(LayoutProbe.self, from: bytes).version,
           version != Transcript.currentVersion {
            guard version > 0 else {
                let reason = "version \(version) is not a layout any TextMouth writes"
                preserveUnusable(url, bytes: bytes, because: reason)
                return .unusable(reason)
            }
            return .unsupportedVersion(version)
        }
        let transcript: Transcript
        do {
            transcript = try decoded(bytes)
        } catch {
            let reason = describe(error)
            preserveUnusable(url, bytes: bytes, because: reason)
            return .unusable(reason)
        }
        if let reason = transcript.validationFailure() {
            preserveUnusable(url, bytes: bytes, because: reason)
            return .unusable(reason)
        }
        return .found(transcript)
    }

    /// The layout version alone, which every layout of transcript.json
    /// keeps under the same key.
    private struct LayoutProbe: Decodable {
        let version: Int
    }

    /// The transcript `bytes` hold, as transcript.json writes it.
    /// - Throws: the decoding error when they hold none.
    static func decoded(_ bytes: Data) throws -> Transcript {
        try decoder.decode(Transcript.self, from: bytes)
    }

    // MARK: Book Information

    /// The line Book Information's Transcript detail shows for `book`, or nil
    /// when it shows none: a book that is not an audiobook, one without a
    /// package of its own, and one without a transcript the sheet could name
    /// (`TranscriptionWording.bookInfoLine(for:)`).
    ///
    /// The transcript is read on a background queue, as a long book's runs to
    /// tens of megabytes, and never downloaded: one only in iCloud is told as
    /// such. The Book Information sheets call it as they appear and show the
    /// detail once it answers.
    static func bookInfoLine(for book: Book) async -> String? {
        guard book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }
        // The package's place is found here, on the caller's actor, so only
        // a URL crosses to the background queue.
        let directory = book.tmbDirectory
        return await OffMainWork.run {
            TranscriptionWording.bookInfoLine(for: read(from: directory))
        }
    }

    // MARK: Writing

    /// The bytes transcript.json holds for `transcript`.
    static func encoded(_ transcript: Transcript) throws -> Data {
        try encoder.encode(transcript)
    }

    /// Writes `transcript` as the transcript.json of the package at
    /// `tmbDir`, replacing any there atomically, and returns the bytes
    /// written. The caller runs it as storage work (`StorageBoundary`).
    @discardableResult
    static func write(_ transcript: Transcript, into tmbDir: URL) throws -> Data {
        let bytes = try encoded(transcript)
        try bytes.write(to: TextMouthPaths.transcriptPath(in: tmbDir), options: .atomic)
        return bytes
    }

    // MARK: Damage

    /// Keeps a copy of the unusable transcript at `url`, holding `bytes`
    /// when they could be read, and writes the one TRANSCRIPT_FILE line
    /// that says so.
    private static func preserveUnusable(_ url: URL, bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: logTag,
            in: .storage,
            standIn: "the book shows no transcript text until it is transcribed again"
        )
    }

    /// `error`, from decoding a transcript, described by its kind and where
    /// in the file it happened. A decoder's own description can quote what
    /// it found there, which may be the book's text, and no log line may
    /// hold book text (`DiagnosticLog`), so it is never used.
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "it could not be decoded"
        }
        switch decodingError {
        case .typeMismatch(_, let context):
            return "a value at \(path(of: context)) has the wrong type"
        case .valueNotFound(_, let context):
            return "a value at \(path(of: context)) is missing"
        case .keyNotFound(let key, let context):
            return "\(path(of: context, appending: key)) is missing"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "it is not valid JSON"
                : "the value at \(path(of: context)) is not usable"
        @unknown default:
            return "it could not be decoded"
        }
    }

    /// The coding path of `context`, with `key` after it when given, as
    /// transcript.json's fields spell it ("files[2].sentences"); "the top"
    /// for an empty path.
    private static func path(of context: DecodingError.Context, appending key: CodingKey? = nil) -> String {
        let keys = context.codingPath + (key.map { [$0] } ?? [])
        guard !keys.isEmpty else { return "the top" }
        return keys.reduce("") { spelled, key in
            if let index = key.intValue {
                return spelled + "[\(index)]"
            }
            return spelled.isEmpty ? key.stringValue : spelled + "." + key.stringValue
        }
    }
}
