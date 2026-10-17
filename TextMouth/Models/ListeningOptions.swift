import Foundation

/// How listening goes on from one item of a feed, or one book of a plain
/// folder, to another (FR19): what happens when an item ends, whether the
/// items already finished are passed over, and whether the item that plays
/// next is downloaded before it is needed. A feed or a folder with no
/// choices of its own keeps no options at all (`Feed.listeningOptions` and
/// `BookFolder.listeningOptions` are nil), so a library written before
/// FR19, and a feed or folder left as it was, behave and save exactly as
/// they always did.
///
/// The type is data only. The rule for which setting wins at the end of a
/// book is `EndOfBookRule`; the words the controls say are
/// `ListeningOptionsWording`.
struct ListeningOptions: Codable, Equatable, Hashable, Sendable {
    /// What happens when an item ends: play the one below, play the one
    /// above, or stop. Nil is "Use the global setting", which follows the
    /// Playback tab's "When book ends".
    var continuation: ReadingList.Continuation?
    /// Whether listening passes over the items already finished when it
    /// goes on to another item. On by default, as the reading list's is.
    var skipsFinished: Bool
    /// Whether the item that plays next is downloaded shortly before the
    /// playing one ends. On by default. Only a feed's is read: a folder's
    /// books are already on this Mac.
    var predownloadsNext: Bool

    /// Options with the given choices; no argument is the standard one.
    init(
        continuation: ReadingList.Continuation? = nil,
        skipsFinished: Bool = true,
        predownloadsNext: Bool = true
    ) {
        self.continuation = continuation
        self.skipsFinished = skipsFinished
        self.predownloadsNext = predownloadsNext
    }

    /// The options of a feed or folder with no choices of its own: nothing
    /// of them is stored.
    static let standard = ListeningOptions()

    /// Whether these are the standard options, which are never stored.
    var isStandard: Bool { self == .standard }

    /// How long before the end of the playing episode the next one is
    /// downloaded: ten minutes, in seconds. The pre-download reads it, and
    /// the control's hint words it.
    static let predownloadLeadTime: TimeInterval = 10 * 60

    /// The choices of "When an item ends", in the order the pop-up buttons
    /// of Feed Info and Folder Settings list them: "Use the global setting"
    /// (nil) first, then each of the reading list's continuations.
    static let continuationChoices: [ReadingList.Continuation?] =
        [nil] + ReadingList.Continuation.allCases.map { Optional($0) }

    /// Whether listening goes on from one item to another under these
    /// options, when the global "When book ends" is `global`: yes for play
    /// the one below or above, no for stop, and, with no choice of its own,
    /// yes exactly when the global one is Continue to Next Book.
    func goesOn(under global: EndOfBookBehavior) -> Bool {
        switch continuation {
        case .playBookBelow, .playBookAbove: return true
        case .stop: return false
        case nil: return global == .continueNext
        }
    }

    // MARK: Coding

    /// The keys of the options in a record.
    private enum CodingKeys: String, CodingKey {
        case continuation, skipsFinished, predownloadsNext
    }

    /// Reads saved options, leniently, so options can never make a feed's
    /// record or the library index unreadable (a feed whose record fails to
    /// decode is a feed the listener loses): a value that is not an object
    /// reads as the standard options, and a key that is missing or unknown,
    /// as a later version might write, reads as its default.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .standard
            return
        }
        continuation = (try? container.decodeIfPresent(ReadingList.Continuation.self, forKey: .continuation)) ?? nil
        skipsFinished = (try? container.decodeIfPresent(Bool.self, forKey: .skipsFinished)) ?? true
        predownloadsNext = (try? container.decodeIfPresent(Bool.self, forKey: .predownloadsNext)) ?? true
    }
}
