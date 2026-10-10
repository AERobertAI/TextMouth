import Foundation

// MARK: - What a Feed Lists and Downloads (FR11)

/// What a feed lists of its items, and what of it downloads by itself
/// (FR11, branch B): the "List and download" choice and its one number, as
/// the listener sets them for every feed (`FeedSettings.itemPolicy`) or for
/// one feed of its own (`Feed.itemPolicyOverride`).
///
/// The choice has three answers (`Choice`), and the number, how many of a
/// feed's newest items count, serves the first and the third:
/// - "Every item listed, newest 5 downloaded", the default: every item is
///   listed, and the newest-N rule keeps the newest 5 downloaded;
/// - "Every item listed, downloads by hand": every item is listed, and
///   nothing downloads by itself;
/// - "Only the newest 5 listed": the newest 5 are listed, less those played
///   without a download, and downloading is by hand (the listener's answer
///   to question 3).
///
/// Each answer is made of what is listed (`listing`) and what downloads by
/// itself (`downloading`). The choice offers three of their four
/// combinations, so the fourth, the newest listed and downloaded, can never
/// be asked for. The number is always one the setting allows
/// (`SettingsPolicy.feedNewestCount`), however it was given.
struct FeedItemPolicy: Equatable, Sendable {
    /// The answers of the "List and download" choice, saved under their raw
    /// values in the preferences store, in config.json (`feedItems`), and in
    /// a feed's record, never under the words the pop-up menu shows, so the
    /// words can change without losing anyone's choice.
    enum Choice: String, CaseIterable, Sendable {
        /// "Every item listed, newest 5 downloaded": the default.
        case everyListedNewestDownloaded
        /// "Every item listed, downloads by hand".
        case everyListedDownloadsByHand
        /// "Only the newest 5 listed", downloads by hand.
        case onlyNewestListed
    }

    /// What a feed's folder lists of its items.
    enum Listing: Equatable, Sendable {
        /// Every item the listener has not deleted.
        case every
        /// The newest of the items, this many, less those played without a
        /// download, and every item downloaded or downloading wherever it
        /// falls: the short list.
        case newest(Int)

        /// The number of newest entries the record keeps besides the items
        /// it always keeps (`FeedReconciler`): the count, or -1 for every
        /// entry.
        var keptEntries: Int {
            switch self {
            case .every: return -1
            case .newest(let count): return count
            }
        }
    }

    /// What of a feed downloads by itself.
    enum Downloading: Equatable, Sendable {
        /// The newest of the items, this many, each downloaded unless it was
        /// played, by the newest-N rule, which also removes the files of its
        /// own downloads once they fall outside them.
        case newest(Int)
        /// Nothing: every download is the listener's to ask for.
        case byHand
    }

    /// The answer chosen.
    var choice: Choice
    /// How many of a feed's newest items the first and third answers count:
    /// always within `SettingsPolicy.feedNewestCount`'s range, a number
    /// outside it being moved to its nearest bound as it is set.
    var newestCount: Int {
        didSet {
            // Setting a property in its own observer stores the value given
            // here without calling the observer again.
            newestCount = SettingsPolicy.feedNewestCount.validated(newestCount)
        }
    }

    /// A policy of `choice`, counting `newestCount` items, which is moved
    /// into the setting's range when it lies outside it.
    init(choice: Choice, newestCount: Int) {
        self.choice = choice
        self.newestCount = SettingsPolicy.feedNewestCount.validated(newestCount)
    }

    /// The policy until the listener picks another: every item listed, the
    /// newest 5 downloaded (the listener's answer of October 7).
    static let standard = FeedItemPolicy(
        choice: SettingsPolicy.feedItems.defaultValue,
        newestCount: SettingsPolicy.feedNewestCount.defaultValue
    )

    /// What the policy lists.
    var listing: Listing {
        choice == .onlyNewestListed ? .newest(newestCount) : .every
    }

    /// What the policy downloads by itself.
    var downloading: Downloading {
        choice == .everyListedNewestDownloaded ? .newest(newestCount) : .byHand
    }
}

// MARK: - In a Feed's Record

extension FeedItemPolicy: Codable {
    /// The keys of a policy in a feed's record, named as config.json names
    /// the global setting's two fields (`feedItems`, `feedNewestCount`).
    private enum CodingKeys: String, CodingKey {
        case choice = "items"
        case newestCount
    }

    /// Reads a policy without ever failing, so one odd value never makes its
    /// feed's whole record unreadable: a choice this version does not know,
    /// as a later version may write, or none, reads as the default; a
    /// number outside the setting's range is moved to its nearest bound,
    /// and none, or one that is not a whole number, reads as the default.
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let rawChoice = Self.leniently(String.self, .choice, in: container)
        let count = Self.leniently(Int.self, .newestCount, in: container)
        self.init(
            choice: SettingsPolicy.feedItems.value(fromRaw: rawChoice),
            newestCount: count ?? SettingsPolicy.feedNewestCount.defaultValue
        )
    }

    /// Writes the choice by its raw value, and the number.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(choice.rawValue, forKey: .choice)
        try container.encode(newestCount, forKey: .newestCount)
    }

    /// The value of `key` in `container`, or nil when there is no container,
    /// or the key is missing, null, or holds a value of another type.
    private static func leniently<Value: Decodable>(
        _ type: Value.Type,
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>?
    ) -> Value? {
        guard let container, let value = try? container.decodeIfPresent(type, forKey: key) else { return nil }
        return value
    }
}
