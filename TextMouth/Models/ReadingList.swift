import Foundation

// MARK: - The Reading List (FR09)

/// The reading list: books from anywhere in the library, in an order the
/// user arranges, and what a book opened from the list does when it ends
/// (FR09). The user asked on October 7, 2026 for "a reading list feature
/// ... which in most ways will act like a manually reorderable folder view
/// but the books can come from anywhere", with options for how to continue
/// and for skipping finished books.
///
/// The list names its books by ID, so a book stays in it wherever it is
/// moved, and holds each book at most once. It is saved in library.json
/// with the rest of the index (`Library.readingList`); a book removed from
/// the library leaves it (`Library.removeBook(id:)`).
struct ReadingList: Codable, Equatable, Sendable {

    // MARK: Options

    /// What a book opened from the reading list does when it ends: play the
    /// book below it in the list, play the book above it, or stop. "Below"
    /// and "above" are where the books are in the list as it is shown and
    /// spoken, which the user found clearer than "next" and "previous".
    enum Continuation: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Play the book after this one in the list: the default.
        case playBookBelow
        /// Play the book before this one in the list.
        case playBookAbove
        /// Stop at the end of the book.
        case stop

        /// The option's identity, for the options bar's picker.
        var id: String { rawValue }

        /// The option's name, as the options bar's picker shows and speaks
        /// it. Saved under its raw value, never under these words, so the
        /// words can change without losing anyone's choice.
        var title: String {
            switch self {
            case .playBookBelow: return "Play the book below"
            case .playBookAbove: return "Play the book above"
            case .stop: return "Stop"
            }
        }

        /// The way through the list the option continues, or nil for Stop.
        var direction: Direction? {
            switch self {
            case .playBookBelow: return .down
            case .playBookAbove: return .up
            case .stop: return nil
            }
        }
    }

    /// A way through the list: down, toward its end, to the book after;
    /// up, toward its start, to the book before.
    enum Direction: CaseIterable, Sendable {
        /// Toward the start of the list: the book above.
        case up
        /// Toward the end of the list: the book below.
        case down

        /// The step through the list's positions: -1 up, +1 down.
        var step: Int {
            self == .up ? -1 : 1
        }

        /// The direction of a step as Move Book Up and Move Book Down give
        /// it: up for a negative step, down for a positive one, and nil for
        /// none.
        init?(step: Int) {
            if step < 0 {
                self = .up
            } else if step > 0 {
                self = .down
            } else {
                return nil
            }
        }
    }

    // MARK: Contents

    /// The books in reading order, by ID, each at most once. Only the
    /// list's own operations change it, and each keeps every ID once.
    private(set) var bookIDs: [UUID]
    /// What a book opened from the list does when it ends.
    var continuation: Continuation
    /// Whether continuing passes over the books already finished.
    var skipsFinished: Bool

    /// A list of `bookIDs`, in that order and each kept once, with the
    /// given options: by default empty, continuing to the book below and
    /// skipping finished books.
    init(bookIDs: [UUID] = [], continuation: Continuation = .playBookBelow, skipsFinished: Bool = true) {
        self.bookIDs = Self.firstOccurrences(of: bookIDs)
        self.continuation = continuation
        self.skipsFinished = skipsFinished
    }

    // MARK: Taking Books Off

    /// Takes the books `ids` names off the list, keeping the others in
    /// their order. Returns the IDs taken off, in the list's order.
    @discardableResult
    mutating func remove(_ ids: Set<UUID>) -> [UUID] {
        let removed = bookIDs.filter { ids.contains($0) }
        guard !removed.isEmpty else { return [] }
        bookIDs.removeAll { ids.contains($0) }
        return removed
    }

    // MARK: Coding

    /// The keys of the list in library.json.
    private enum CodingKeys: String, CodingKey {
        case bookIDs, continuation, skipsFinished
    }

    /// Reads a saved list, leniently, so the list can never make the whole
    /// library index unreadable: an ID that cannot be read is skipped and
    /// the rest kept, an ID listed twice is kept once, where it first
    /// appears, and an option that is missing or unknown, as a later
    /// version might write, reads as its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var ids: [UUID] = []
        if var entries = try? container.nestedUnkeyedContainer(forKey: .bookIDs) {
            while !entries.isAtEnd {
                let position = entries.currentIndex
                if let id = try? entries.decode(UUID.self) {
                    ids.append(id)
                } else {
                    // Step over the entry that is not an ID.
                    _ = try? entries.decode(SkippedEntry.self)
                }
                // Never stay on an entry that would read neither way.
                if entries.currentIndex == position { break }
            }
        }
        bookIDs = Self.firstOccurrences(of: ids)
        continuation = (try? container.decodeIfPresent(Continuation.self, forKey: .continuation)) ?? .playBookBelow
        skipsFinished = (try? container.decodeIfPresent(Bool.self, forKey: .skipsFinished)) ?? true
    }

    /// An entry of the saved list that is read only to step over it.
    private struct SkippedEntry: Decodable {
        init(from decoder: Decoder) {}
    }

    /// `ids` with every repeat left out, so each ID keeps the place where it
    /// first appears.
    private static func firstOccurrences(of ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
