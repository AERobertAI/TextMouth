import SwiftUI

/// What the import overlay shows at one moment: the bar's books done of the
/// total, which is 0 of 0 while the bar only spins, and the line beneath it.
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

    /// The state a ZIP batch's `progress` shows. The bar and its count speak
    /// of books, so while the archive is extracted the bar is left
    /// indeterminate and the message counts the archive's items extracted,
    /// so the overlay moves before the first book imports; once books
    /// import, the bar and the message count them.
    init(_ progress: ZipImportProgress) {
        switch progress {
        case let .extracting(archive, done, total):
            message = "Extracting “\(archive)”: \(done) of \(total) items..."
        case let .importing(done, total):
            self.current = done
            self.total = total
            message = "Importing book \(done) of \(total)..."
        }
    }
}

/// The progress of the imports under way, as the Library window's import
/// overlay shows it (`LibraryWindowView.importProgressOverlay(for:)`).
///
/// It is an object of its own, which only the overlay observes, as the text
/// extraction's progress is (`TextExtractionProgress`, TODO PERF12): a ZIP
/// batch reports its progress many times over, and each report published
/// by the library model itself would redraw every Library window's list.
/// The library model owns one and changes it on the main thread; whether the
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

    /// Shows how far a ZIP batch has got (TODO I05).
    func receive(_ progress: ZipImportProgress) {
        state = ImportProgressState(progress)
    }

    /// Shows nothing more: an import ended, or none is under way.
    func clear() {
        state = ImportProgressState()
    }
}
