import Combine
import Foundation
import SwiftUI

/// What a view shows of its reader, republished only when it changes
/// (PERF30).
///
/// A reader publishes whenever anything its window shows changes, as often as
/// once a second while it plays (it was eight times a second before the
/// window's shown state, `ReaderShownState`), and a view observing the whole
/// reader is rebuilt each time, whatever it shows: the headings sheet rebuilt every row, and the voice
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

/// A sheet over a reader whose only input is that reader: everything else it
/// shows comes from its own state, its environment, and its snapshot of the
/// reader, which SwiftUI follows apart from this comparison. So two such
/// sheets are the same when they show the same reader (PERF30). The reader
/// view presenting a sheet makes it again each time it draws, about once a
/// second while a book plays, and SwiftUI's own comparison of the new sheet
/// with the old does not always find them the same: the bookmark panel, once
/// its focus had moved, drew again every time.
protocol SheetOverOneReader: View, Equatable {
    /// The reader the sheet shows, its only input.
    nonisolated var viewModel: ReaderViewModel { get }
}

extension SheetOverOneReader {
    /// Whether two sheets show the same reader.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
    }
}
