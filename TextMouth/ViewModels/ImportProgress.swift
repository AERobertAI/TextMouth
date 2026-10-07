import SwiftUI

/// What the import overlay shows at one moment (FR10): the bar's books done
/// of the total, which is 0 of 0 while the bar only spins, and the line
/// beneath it, which says what the import is doing.
struct ImportProgressState: Equatable {
    /// The books done, which the bar and its count show.
    var current = 0
    /// The books the bar counts toward; 0 while the bar only spins.
    var total = 0
    /// The line under the bar: what the import is doing, or empty.
    var message = ""

    /// The state that shows `message` alone, under a bar that only spins:
    /// an import starting or waiting.
    init(message: String = "") {
        self.message = message
    }

    /// Takes a ZIP batch's `progress` (TODO I05, FR10). While the archive is
    /// extracted the bar only spins and the line counts the archive's items,
    /// so the overlay moves before the first book; once books import, the
    /// bar counts the books done, and the line names the book under way and
    /// the step it is at, which it keeps until the next book begins.
    mutating func receive(_ progress: ZipImportProgress) {
        switch progress {
        case let .extracting(archive, done, total):
            self = ImportProgressState(message: ImportProgressWording.extracting(archive: archive, done: done, total: total))
        case let .importingBook(number, total, book, step):
            // The books before this one are done.
            current = number - 1
            self.total = total
            message = ImportProgressWording.book(book, number: number, of: total, step: step)
        case let .importing(done, total):
            current = done
            self.total = total
        }
    }

    /// The lines the overlay shows under its title, in order: the books
    /// done of the total, while the bar counts them, and the line that says
    /// what the import is doing.
    var lines: [String] {
        let count = total > 0 ? [ImportProgressWording.count(done: current, of: total)] : []
        return count + [message]
    }

    /// What VoiceOver reads for the overlay: its title and every line it
    /// shows, as "Importing Books: 2 of 100 books processed. Book 3 of 100:
    /// “Moby Dick.epub”, reading its text."
    var spokenStatus: String {
        ImportProgressWording.spokenStatus(lines)
    }
}

/// The progress of the imports under way, as the Library window's import
/// overlay shows it (`LibraryWindowView.importProgressOverlay(for:)`).
///
/// It is an object of its own, which only the overlay observes, as the text
/// extraction's progress is (`TextExtractionProgress`, TODO PERF12): a ZIP
/// batch reports every step of every book, and each report published by the
/// library model itself would redraw every Library window's list. The
/// library model owns one and changes it on the main thread; whether the
/// overlay shows at all is still the model's `isImporting`.
@MainActor
final class ImportProgress: ObservableObject {
    /// What the overlay shows now.
    @Published private(set) var state = ImportProgressState()

    /// Shows `message` alone, under a bar that only spins: an import
    /// starting, or waiting for a data-directory move (TODO S04).
    func show(_ message: String) {
        state = ImportProgressState(message: message)
    }

    /// Takes a ZIP batch's `progress`: how far its extraction has got, the
    /// book under way and its step, and the books done (TODO I05, FR10).
    func receive(_ progress: ZipImportProgress) {
        state.receive(progress)
    }

    /// Shows nothing more: an import ended, or none is under way.
    func clear() {
        state = ImportProgressState()
    }
}
