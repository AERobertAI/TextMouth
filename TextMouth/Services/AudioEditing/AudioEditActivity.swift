import Foundation
import os

/// Which books' audio is in use now in a way an original must stay for
/// (FR04): books open in a reader, and books whose audio is being edited or
/// rendered. The original policy's sweep never deletes the original of a
/// book in use (`AudioOriginalSweep`).
///
/// The library model keeps one, mirroring its readers into it
/// (`LibraryViewModel.openBookIDs`); an edit session and a render hold a use
/// of their book from before they first read its edit history until they
/// are done (`beginUse(of:)`). The sweep asks while it holds the history
/// store's lock, and a render takes that lock to read the history only after
/// its use has begun, so a sweep either sees the use and leaves the original
/// alone, or has finished deleting it before the render reads the history,
/// which then no longer lists it.
///
/// Every method may be called from any thread.
final class AudioEditActivity: Sendable {
    /// What is in use, behind a lock.
    private struct State: Sendable {
        /// The books open in readers.
        var openInReaders: Set<UUID> = []
        /// How many uses of each book's audio are under way: edit sessions
        /// and renders.
        var uses: [UUID: Int] = [:]
    }

    /// The state, guarded by an unfair lock that is held only to read or
    /// change it, never across any work.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Notes that the books `ids` are the ones open in readers now.
    func setOpenInReaders(_ ids: Set<UUID>) {
        state.withLock { $0.openInReaders = ids }
    }

    /// Notes that `bookID`'s audio is being edited or rendered, until a
    /// matching `endUse(of:)`. Uses of one book add up, so a render begun
    /// from an open edit session ends without ending the session's use.
    func beginUse(of bookID: UUID) {
        state.withLock { $0.uses[bookID, default: 0] += 1 }
    }

    /// Ends one use of `bookID`'s audio begun with `beginUse(of:)`.
    func endUse(of bookID: UUID) {
        state.withLock { state in
            guard let count = state.uses[bookID] else { return }
            state.uses[bookID] = count > 1 ? count - 1 : nil
        }
    }

    /// A use of `bookID`'s audio that ends when the lease is ended or
    /// released, whichever comes first: for an edit session, which lasts as
    /// long as its window.
    func lease(_ bookID: UUID) -> Lease {
        beginUse(of: bookID)
        return Lease(activity: self, bookID: bookID)
    }

    /// One use of a book's audio, ended exactly once: by `end()`, or when the
    /// lease is released.
    final class Lease: Sendable {
        /// The activity the use is noted in.
        private let activity: AudioEditActivity
        /// The book whose audio is in use.
        let bookID: UUID
        /// Whether the use has ended, behind a lock, so it ends once.
        private let ended = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(activity: AudioEditActivity, bookID: UUID) {
            self.activity = activity
            self.bookID = bookID
        }

        /// Ends the use, unless it has ended already.
        func end() {
            let wasEnded = ended.withLock { ended in
                defer { ended = true }
                return ended
            }
            if !wasEnded {
                activity.endUse(of: bookID)
            }
        }

        deinit {
            end()
        }
    }

    /// Whether `bookID`'s audio is being edited or rendered.
    func isBeingEdited(_ bookID: UUID) -> Bool {
        state.withLock { $0.uses[bookID] != nil }
    }

    /// Whether `bookID` is open in a reader.
    func isOpenInReader(_ bookID: UUID) -> Bool {
        state.withLock { $0.openInReaders.contains(bookID) }
    }

    /// Whether `bookID` is in use: open in a reader, or its audio being
    /// edited or rendered.
    func isInUse(_ bookID: UUID) -> Bool {
        state.withLock { $0.openInReaders.contains(bookID) || $0.uses[bookID] != nil }
    }
}
