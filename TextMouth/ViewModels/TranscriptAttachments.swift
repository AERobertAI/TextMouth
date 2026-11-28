import Combine
import Foundation
import UniformTypeIdentifiers

/// The audiobooks a transcript is being attached to with Attach
/// Transcript… (FMT23): each from the moment the listener has chosen a file
/// until its transcript is saved or refused, or the confirmation before it
/// replaces the book's own transcript goes without Replace.
///
/// The command is unavailable for such a book (`canAttach(_:attaching:)`),
/// so a second file is never attached over the first while that is read,
/// confirmed, or saved. The reader's Book menu observes it, and dims the
/// command while its book is here.
@MainActor
final class TranscriptAttachments: ObservableObject {
    /// The app's record.
    static let shared = TranscriptAttachments()

    /// The books a transcript is being attached to, by ID.
    @Published private(set) var bookIDs: Set<UUID> = []

    /// A record with no book in it. The app uses `shared`; a test may make
    /// its own.
    init() {}

    /// Records that a transcript is being attached to the book `bookID`.
    /// Recording it twice changes nothing, and publishes nothing.
    func begin(_ bookID: UUID) {
        guard !bookIDs.contains(bookID) else { return }
        bookIDs.insert(bookID)
    }

    /// Records that no transcript is being attached to the book `bookID`
    /// any more. A book not recorded changes nothing, and publishes nothing.
    func end(_ bookID: UUID) {
        guard bookIDs.contains(bookID) else { return }
        bookIDs.remove(bookID)
    }

    // MARK: The Command's Rules

    /// Whether Attach Transcript… can attach a transcript to `book`: an
    /// audiobook in a package of its own, as Transcribe Audio… transcribes
    /// (`LibraryAudioCommand.isTranscribable(_:)`), that no transcript is
    /// being attached to, as `attaching` lists them.
    static func canAttach(_ book: Book, attaching: Set<UUID>) -> Bool {
        LibraryAudioCommand.isTranscribable(book) && !attaching.contains(book.id)
    }

    /// Whether Transcribe Audio… can transcribe `book`: an audiobook in a
    /// package of its own (`LibraryAudioCommand.isTranscribable(_:)`) that
    /// no transcript is being attached to, as `attaching` lists them. A
    /// transcription begun while a file is attached would save its own
    /// transcript over the file's moments later (follow-up 7).
    static func canTranscribe(_ book: Book, attaching: Set<UUID>) -> Bool {
        LibraryAudioCommand.isTranscribable(book) && !attaching.contains(book.id)
    }

    /// The kinds of file the Open panel offers: WebVTT and SubRip, each by
    /// its extension (`TimedTextFormat.cueFileFormats`), as the system
    /// knows it or as a type of its own when it knows none.
    static var fileTypes: [UTType] {
        TimedTextFormat.cueFileFormats.compactMap { UTType(filenameExtension: $0.fileExtension) }
    }

    /// Whether the file the listener chose can be read at all: a regular
    /// file, or a link to one. Opening a named pipe or another special file
    /// waits for a writer that never comes, and would leave the book
    /// "being attached to" for good, so nothing but a regular file is read.
    /// A look at the file system, which reads nothing.
    static func isReadableFile(at url: URL) -> Bool {
        // The listener chose the file, so a link is followed to what it
        // names, unlike a file found beside the audio at import.
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// The folder the Open panel starts in for `book`: where the book was
    /// imported from (`Book.sourceFilePath`), where its transcript most
    /// likely lies. That is the folder itself for a book imported from a
    /// folder of tracks, and the folder holding the file for a book
    /// imported from one file. Nil when the book records no source, or the
    /// folder is not there now, as when it was on a disk not connected: the
    /// panel then opens where it last did.
    ///
    /// It looks at the file system, which can stall for a long time on a
    /// disk that is a network share or cloud drive and not answering, so the
    /// Open panel asks it off the main thread (`chooseTranscriptFile`).
    static func startingFolder(for book: Book) -> URL? {
        startingFolder(forSource: book.sourceFilePath)
    }

    /// The folder `startingFolder(for:)` finds for a book recorded as
    /// imported from `sourcePath`; a plain string, and not bound to the main
    /// actor, so it can run on another thread.
    nonisolated static func startingFolder(forSource sourcePath: String?) -> URL? {
        // A source must be a whole path: an empty one would name the
        // current directory.
        guard let source = sourcePath, source.hasPrefix("/") else { return nil }
        let sourceURL = URL(fileURLWithPath: source)
        let folder = isFolder(sourceURL) ? sourceURL : sourceURL.deletingLastPathComponent()
        return isFolder(folder) ? folder : nil
    }

    /// Whether a folder is at `url` (one look at the file system, which
    /// downloads nothing).
    nonisolated private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
