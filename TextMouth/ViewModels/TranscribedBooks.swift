import Combine
import Foundation

/// The note after a book's title in its library row (FR05): "Transcribing"
/// while its audio is transcribed, and "Transcribed" once it has a
/// transcript, shown and spoken, as the cloud notes are.
enum TranscriptionRowNote: Equatable, Sendable {
    /// The book has a transcript.
    case transcribed
    /// The book is being transcribed now.
    case transcribing

    /// The note's words, shown and spoken.
    var text: String {
        switch self {
        case .transcribed: return TranscriptionWording.transcribedNote
        case .transcribing: return TranscriptionWording.transcribingNote
        }
    }

    /// The SF Symbol drawn before the words. The picture only repeats them,
    /// and VoiceOver never reads it.
    var symbolName: String {
        switch self {
        case .transcribed: return "text.quote"
        case .transcribing: return "waveform"
        }
    }
}

/// Which audiobooks have a transcript, and which is being transcribed, for
/// the library rows' notes and commands (FR05).
///
/// A book's record notes its transcript in its package alone
/// (`BookState.transcript`), never in library.json, so a row cannot carry
/// it. This store looks for each audiobook's transcript.json instead, off
/// the main thread, without reading or downloading anything: as a Library
/// window appears, as the number of books changes, and as TextMouth becomes
/// active, when another Mac sharing the library may have transcribed a
/// book. A transcription that finishes, and a transcript deleted, are
/// recorded at once, and win over a look begun before them.
@MainActor
final class TranscribedBooks: ObservableObject {
    /// The app's store.
    static let shared = TranscribedBooks()

    /// The books with a transcript, by ID.
    @Published private(set) var bookIDs: Set<UUID> = []
    /// The book being transcribed now, if any.
    @Published private(set) var transcribingBookID: UUID?

    /// How many looks have begun: only the latest one records what it found.
    private var lookCount = 0
    /// How many records have been made, a transcription's or a deletion's.
    private var recordCount = 0
    /// When each book was last recorded, by `recordCount`, so a look begun
    /// before leaves the record alone.
    private var recordedAt: [UUID: Int] = [:]

    /// A store with nothing recorded. The app uses `shared`; tests make
    /// their own.
    init() {}

    /// Whether the book `bookID` has a transcript.
    func contains(_ bookID: UUID) -> Bool {
        bookIDs.contains(bookID)
    }

    /// The note the row of the book `bookID` shows, or nil for none.
    func note(for bookID: UUID) -> TranscriptionRowNote? {
        if transcribingBookID == bookID { return .transcribing }
        return bookIDs.contains(bookID) ? .transcribed : nil
    }

    /// Records whether the book `bookID` has a transcript, as a
    /// transcription saving one or a deletion removing it found.
    func record(_ bookID: UUID, isTranscribed: Bool) {
        recordCount += 1
        recordedAt[bookID] = recordCount
        if isTranscribed {
            bookIDs.insert(bookID)
        } else {
            bookIDs.remove(bookID)
        }
    }

    /// Records the book being transcribed now, or none.
    func setTranscribing(_ bookID: UUID?) {
        guard transcribingBookID != bookID else { return }
        transcribingBookID = bookID
    }

    /// Looks for each of `books`' transcript.json off the main thread and
    /// records what it found, in one change, published only when something
    /// changed. Only audiobooks in packages of their own are looked at; any
    /// other book has no transcript. A look superseded by a later one
    /// records nothing, and a book recorded after this look began keeps
    /// its record.
    func refresh(_ books: [Book]) async {
        lookCount += 1
        let look = lookCount
        let recordsBefore = recordCount
        let transcripts = books.filter(LibraryAudioCommand.isTranscribable).map {
            (id: $0.id, url: TextMouthPaths.transcriptPath(in: $0.tmbDirectory))
        }
        // A look at the folder: never a read, so nothing is downloaded.
        let found = await OffMainWork.run(on: .global(qos: .utility)) {
            Set(transcripts.filter { FileManager.default.fileExists(atPath: $0.url.path) }.map(\.id))
        }
        guard look == lookCount else { return }
        var updated = found
        for (bookID, recorded) in recordedAt where recorded > recordsBefore {
            if bookIDs.contains(bookID) {
                updated.insert(bookID)
            } else {
                updated.remove(bookID)
            }
        }
        if updated != bookIDs {
            bookIDs = updated
        }
    }
}
