import Foundation

/// How a book came to be, when TextMouth made it rather than imported it:
/// today, a recording from a microphone (FR04). The Record window writes it
/// when it saves a take as an audiobook; the audio editor (a later task)
/// and Export read it.
///
/// It is kept in the book's package as origin.json, beside bookInfo.json,
/// rather than in the package record or library.json: older versions of
/// TextMouth read both of those and write them back without fields they do
/// not know, while they leave a file they do not know alone, so the record
/// survives them. No save of a book's state touches it, and it moves,
/// syncs, and is deleted with the package. A book without one was imported.
///
/// A recording's package is laid out as:
///
///     <Title>-<Author>-<date>-<ID>.tmb/
///         bookInfo.json, contentIndex.json   the package record, as for every book
///         <Title>.m4a                        the book's audio: AAC, mono, its title tagged
///         original-take.caf                  the take, 16-bit PCM, while the policy keeps it
///         origin.json                        this record
struct BookOrigin: Codable, Equatable, Sendable {
    /// What made the book.
    enum Kind: String, Codable, Sendable {
        /// A recording from a microphone, saved from the Record window.
        case recording
    }

    /// The original take kept in the package, and how long it stays.
    struct OriginalTake: Codable, Equatable, Sendable {
        /// Its file's name at the package root: always
        /// `BookOrigin.originalTakeFileName` today.
        var fileName: String
        /// When the book's audio was last made from the take: when the
        /// recording was saved, and, once the editor exists, each time an
        /// edit is saved. A deletion after some days counts from here.
        var lastEditedAt: Date
        /// This book's own policy, which wins over the global setting
        /// (`RecordingOriginalPolicy.global(in:)`); nil follows the global
        /// setting. Nothing sets one yet: the per-book override the user
        /// asked for comes with the editor.
        var policyOverride: RecordingOriginalPolicy?

        /// The policy this take is kept under: its book's own, or else
        /// `global`.
        func effectivePolicy(global: RecordingOriginalPolicy) -> RecordingOriginalPolicy {
            policyOverride ?? global
        }
    }

    /// What made the book.
    var kind: Kind
    /// When recording started.
    var recordedAt: Date
    /// How long the take lasted, in seconds, pauses left out.
    var duration: TimeInterval
    /// The microphone the take was recorded from, by the name macOS showed.
    var inputDeviceName: String
    /// The original take kept in the package, or nil when none is kept: the
    /// policy deleted it, or never kept it.
    var originalTake: OriginalTake?

    /// The record's file name at the package root.
    static let fileName = "origin.json"
    /// The original take's file name at the package root.
    static let originalTakeFileName = "original-take.caf"

    // MARK: Reading and Writing

    /// How origin.json is written: readable, keys sorted, dates in ISO 8601,
    /// as bookInfo.json is.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// How origin.json is read.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The record in the package at `package`, or nil when it has none, or
    /// one that cannot be read, which counts as none. Never downloads: a
    /// record only in the cloud throws the refusal
    /// `DatalessFiles.isDownloadRefusal` recognizes.
    static func load(fromPackage package: URL) throws -> BookOrigin? {
        let data: Data
        do {
            data = try DatalessFiles.withoutDownloading {
                try Data(contentsOf: package.appendingPathComponent(fileName))
            }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            return nil
        }
        return try? decoder.decode(BookOrigin.self, from: data)
    }

    /// Writes this record into the package at `package`, replacing any
    /// record there in one step.
    func save(toPackage package: URL) throws {
        try Self.encoder.encode(self).write(to: package.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Whether `name` can be an original take's file name: one file at the
    /// package root, never a path that could reach outside the package,
    /// however origin.json was edited.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
