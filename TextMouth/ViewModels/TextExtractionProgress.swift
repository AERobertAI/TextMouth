import SwiftUI

/// The text extraction batch's progress (TODO PERF12): whether a batch
/// runs, how many of its books are done, and the line its overlay shows.
///
/// These used to be four published properties of the library model, so
/// each finished book published the whole model, which re-rendered every
/// Library window's list. They are an object of their own now, which only
/// the views that show them observe (`ProgressObserver`): the overlay over
/// each Library window and the Storage settings tab.
@MainActor
final class TextExtractionProgress: ObservableObject {
    /// Whether a batch runs. A second batch is refused while one does.
    @Published private(set) var isExtracting = false
    /// How many of the batch's books are done.
    @Published private(set) var current = 0
    /// How many books the batch has.
    @Published private(set) var total = 0
    /// What the overlay says, as in "Updating text cache: 3 of 60...";
    /// empty while no batch runs.
    @Published private(set) var message = ""

    /// What the running batch does, as its message names it.
    private var activity = ""

    /// Starts a batch of `total` books that does `activity`, such as
    /// "Updating text cache", with none of them done.
    func begin(_ activity: String, total: Int) {
        self.activity = activity
        self.total = total
        current = 0
        message = Self.message(activity, done: 0, of: total)
        isExtracting = true
    }

    /// Counts one more of the batch's books as done.
    func advance() {
        current += 1
        message = Self.message(activity, done: current, of: total)
    }

    /// Ends the batch. Its counts stay, as before, until the next begins.
    func end() {
        isExtracting = false
        message = ""
    }

    /// The overlay's line for a batch that has done `done` of `total`
    /// books.
    static func message(_ activity: String, done: Int, of total: Int) -> String {
        "\(activity): \(done) of \(total)..."
    }
}
