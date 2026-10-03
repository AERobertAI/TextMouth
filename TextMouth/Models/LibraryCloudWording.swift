import Foundation

/// The words of the library list's cloud commands (FR02): their titles,
/// which are also their VoiceOver action names, and what they announce.
///
/// The words for a book's state and for why an operation failed belong to
/// the contract (`BookCloudState`, `BookCloudError.explanation(in:)`); these
/// only name the commands and say what a command did with the books it
/// acted on.
enum LibraryCloudWording {
    // MARK: - Titles

    /// Download Now's title: "Download Now" for the one book a menu is for,
    /// or "Download 3 Books" for `count` books of a selection.
    static func downloadTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Download \(titleCount(count))" : "Download Now"
    }

    /// Remove Download's title: "Remove Download" for the one book a menu is
    /// for, or "Remove Downloads of 3 Books" for `count` books of a
    /// selection ("Remove Download of 1 Book" for one).
    static func removeDownloadTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return "Remove Download" }
        return "Remove \(count == 1 ? "Download" : "Downloads") of \(titleCount(count))"
    }

    /// Show in Finder's title: "Show in Finder" for the one book a menu is
    /// for, or "Show 3 Books in Finder" for `count` books of a selection.
    static func showInFinderTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Show \(titleCount(count)) in Finder" : "Show in Finder"
    }

    /// `count` books in a command's title: "1 Book", "3 Books".
    private static func titleCount(_ count: Int) -> String {
        CountWording.phrase(count, singular: "Book", plural: "Books")
    }

    // MARK: - Download Now

    /// What Download Now announces as it starts: "Downloading Moby-Dick"
    /// for one book, "Downloading 3 books" for several.
    static func downloadStarted(titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return "Downloading \(title)"
        }
        return "Downloading \(CountWording.books(titles.count))"
    }

    /// What Download Now announces once every book it started has ended:
    /// one summary, such as "Moby-Dick downloaded" or "Downloaded 3 books",
    /// then the books that weren't downloaded and why. Nil when nothing
    /// ended, which happens only when every book left the library first.
    /// - Parameters:
    ///   - downloaded: The titles of the books now on this Mac, in list order.
    ///   - failed: The books whose download failed, with the explanation of
    ///     each failure, in list order.
    static func downloadFinished(downloaded: [String], failed: [(title: String, explanation: String)]) -> String? {
        var sentences: [String] = []
        if downloaded.count == 1, let title = downloaded.first {
            sentences.append("\(title) downloaded")
        } else if downloaded.count > 1 {
            sentences.append("Downloaded \(CountWording.books(downloaded.count))")
        }
        if failed.count == 1, let failure = failed.first {
            sentences.append("\(failure.title) wasn't downloaded")
        } else if failed.count > 1 {
            let books = CountWording.phrase(failed.count, singular: "book wasn't", plural: "books weren't")
            sentences.append("\(books) downloaded: \(list(failed.map(\.title)))")
        }
        return summary(sentences, explanations: failed.map(\.explanation))
    }

    // MARK: - Remove Download

    /// What Remove Download announces, and shows when anything was refused.
    /// A single book refused hears only the explanation, since the book is
    /// the one just chosen; otherwise the removed books come first, then the
    /// refused ones and why. Nil when nothing was attempted.
    /// - Parameters:
    ///   - removed: The titles of the books whose downloads were removed.
    ///   - refused: The books whose downloads stay, with the explanation of
    ///     each refusal.
    ///   - provider: The sync service the books stay in, when known.
    static func removalFinished(
        removed: [String],
        refused: [(title: String, explanation: String)],
        provider: CloudProvider?
    ) -> String? {
        if removed.isEmpty, refused.count == 1, let refusal = refused.first {
            return refusal.explanation
        }
        let service = provider?.displayName ?? "the cloud"
        var sentences: [String] = []
        if removed.count == 1, let title = removed.first {
            sentences.append("Removed the download of \(title)")
            sentences.append("It stays in \(service)")
        } else if removed.count > 1 {
            sentences.append("Removed the downloads of \(CountWording.books(removed.count))")
            sentences.append("They stay in \(service)")
        }
        if refused.count == 1, let refusal = refused.first {
            sentences.append("The download of \(refusal.title) wasn't removed")
        } else if refused.count > 1 {
            sentences.append(
                "The downloads of \(CountWording.books(refused.count)) weren't removed: "
                    + list(refused.map(\.title))
            )
        }
        // A removal alone ends with a period, as a full sentence about where
        // the book stays.
        guard let text = summary(sentences, explanations: refused.map(\.explanation)) else { return nil }
        return refused.isEmpty ? text + "." : text
    }

    /// The title of the alert that shows Remove Download's refusals, for
    /// `refusedCount` books.
    static func removalRefusedTitle(refusedCount: Int) -> String {
        refusedCount == 1 ? "Download Not Removed" : "Downloads Not Removed"
    }

    // MARK: - Helpers

    /// `sentences` joined into one announcement, followed by each distinct
    /// explanation once, in the order they first came; nil when there is
    /// nothing to say. The explanations end with their own periods.
    private static func summary(_ sentences: [String], explanations: [String]) -> String? {
        guard !sentences.isEmpty else { return nil }
        var distinct: [String] = []
        for explanation in explanations where !distinct.contains(explanation) {
            distinct.append(explanation)
        }
        let text = sentences.joined(separator: ". ")
        return distinct.isEmpty ? text : text + ". " + distinct.joined(separator: " ")
    }

    /// `items` as a list in a sentence: "A", "A and B", "A, B, and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}
