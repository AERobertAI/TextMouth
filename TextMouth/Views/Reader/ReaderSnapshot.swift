import Combine
import Foundation

/// What a view shows of its reader, republished only when it changes
/// (PERF30).
///
/// A reader publishes eight times a second while it plays, as its position
/// moves, and a view observing the whole reader is rebuilt each time,
/// whatever it shows: the headings sheet rebuilt every row, and the voice
/// sheet asked the system for its voices twice. A view holding a snapshot
/// of what it shows is rebuilt only when that changes. The snapshot reads
/// the reader after each change is stored, since a reader announces a change
/// just before making it, and republishes only a value that differs.
@MainActor
final class ReaderSnapshot<Value: Equatable>: ObservableObject {
    /// What the view shows, as of the reader's latest change.
    @Published private(set) var value: Value

    /// The reader's announcements of change, heard while the snapshot lasts.
    private var subscription: AnyCancellable?

    /// A snapshot of `reader` that `read` takes now and after each change.
    init(of reader: ReaderViewModel, _ read: @escaping @MainActor (ReaderViewModel) -> Value) {
        value = read(reader)
        subscription = reader.objectWillChange
            // Heard before the change is stored: read on the main queue's
            // next turn, by which time it is.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak reader] _ in
                // Delivered on the main queue, as `receive(on:)` asks.
                MainActor.assumeIsolated {
                    guard let self, let reader else { return }
                    let latest = read(reader)
                    if latest != self.value {
                        self.value = latest
                    }
                }
            }
    }
}
