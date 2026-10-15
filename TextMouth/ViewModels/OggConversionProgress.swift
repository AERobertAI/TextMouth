import SwiftUI

/// The conversion of the library's Ogg audio to AAC (B06): which books are
/// being converted, which their readers refuse to play, and how far the book
/// under way has got, which the Library window's overlay shows, as in
/// "Converting audio: 12 of 176 tracks of “Harbor Dramas”".
///
/// An object of its own, as the text extraction's progress is
/// (`TextExtractionProgress`), so a track converted redraws only the views
/// that show it.
@MainActor
final class OggConversionProgress: ObservableObject {
    /// The overlay's title.
    nonisolated static let title = "Converting Audio"
    /// What the overlay's count counts, agreeing with the total: "12 of 176
    /// tracks converted", "0 of 1 track converted".
    nonisolated static let itemNoun = CountWording.Noun(singular: "track converted", plural: "tracks converted")

    /// Whether a book is being converted, which shows the overlay.
    @Published private(set) var isConverting = false
    /// How many of the book's tracks are converted.
    @Published private(set) var current = 0
    /// How many tracks the book has to convert.
    @Published private(set) var total = 0
    /// What the overlay says; empty while nothing converts.
    @Published private(set) var message = ""
    /// The book being converted, and its title, while one is.
    private var underWay: (id: UUID, title: String)?
    /// The books a reader asked to convert, waiting their turn.
    private var queued: Set<UUID> = []
    /// The books whose conversion failed since this launch (a track that
    /// would not convert, or one the watchdog killed): they wait for the next
    /// launch, and are never tried again before it (B09).
    private var failed: Set<UUID> = []
    /// The last conversion in line: each one starts once the one before it
    /// has ended, so two books never convert at once.
    private var lastInLine: Task<Void, Never>?

    /// Whether the book `bookID` is being converted, or waits its turn, so
    /// its reader must not play it.
    func isConverting(_ bookID: UUID) -> Bool {
        underWay?.id == bookID || queued.contains(bookID)
    }

    /// Notes that the conversion of the book `bookID` failed, so nothing
    /// tries it again before the next launch.
    func markFailed(_ bookID: UUID) {
        failed.insert(bookID)
    }

    /// Whether the conversion of the book `bookID` has failed since this
    /// launch.
    func hasFailed(_ bookID: UUID) -> Bool {
        failed.contains(bookID)
    }

    /// Runs `work`, the conversion of one book or of the library's, once
    /// every conversion put in line before it has ended. The book `bookID`,
    /// when given, counts as converting from now until `work` ends.
    @discardableResult
    func enqueue(bookID: UUID? = nil, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let bookID { queued.insert(bookID) }
        let previous = lastInLine
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            if let bookID { self?.queued.remove(bookID) }
        }
        lastInLine = task
        return task
    }

    /// Begins the conversion of `tracks` tracks of the book `bookID`, titled
    /// `title`, with none done.
    func begin(bookID: UUID, title: String, tracks: Int) {
        underWay = (bookID, title)
        total = tracks
        current = 0
        message = Self.message(done: 0, of: tracks, title: title)
        isConverting = true
    }

    /// Notes that `done` of the book's tracks are converted. A count older
    /// than the one shown, arriving late, changes nothing.
    func reach(_ done: Int) {
        guard let underWay, done > current else { return }
        current = min(done, total)
        message = Self.message(done: current, of: total, title: underWay.title)
    }

    /// Ends the conversion of the book `bookID`, whatever came of it.
    func end(bookID: UUID) {
        guard underWay?.id == bookID else { return }
        underWay = nil
        isConverting = false
        current = 0
        total = 0
        message = ""
    }

    /// The overlay's line: "Converting audio: 12 of 176 tracks of “Harbor
    /// Dramas”".
    nonisolated static func message(done: Int, of total: Int, title: String) -> String {
        "Converting audio: \(ImportProgressWording.tracks(done: done, of: total)) of “\(title)”"
    }
}
