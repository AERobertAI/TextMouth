import Foundation

/// Why a playlist is refused, in words a listener hears (FMT10). An alert
/// reads it after the file's name and the step that failed ("Could not
/// import “mix.m3u”. Reading the file failed: …"), so each sentence
/// stands whole.
enum PlaylistImportError: LocalizedError, Equatable {
    /// The playlist is an HLS stream, a list of pieces of one broadcast
    /// on the web, not of files.
    case streaming
    /// Every entry of the playlist is a web address.
    case onlyWebAddresses
    /// No entry is an audio file inside the playlist's own folder. The
    /// entries skipped are told, so the listener sees why each was left out.
    case noTrack(skipped: [M3UPlaylist.Skipped])

    /// The sentence for the refusal, from `PlaylistImportWording`.
    var errorDescription: String? {
        switch self {
        case .streaming:
            return PlaylistImportWording.streaming
        case .onlyWebAddresses:
            return PlaylistImportWording.onlyWebAddresses
        case let .noTrack(skipped):
            return PlaylistImportWording.noTrack(skipped: skipped)
        }
    }
}

/// The sentences a playlist import says: its refusals and the notice of the
/// entries it skipped. One type holds them so the refusal and the notice
/// list the skipped entries the same way, and a test pins every word.
enum PlaylistImportWording {
    /// The most skipped entries a sentence names; the rest are counted.
    static let namedLimit = 10

    /// The refusal of an HLS stream.
    static let streaming = "It is a streaming playlist for audio on the web, which TextMouth does not import."

    /// The refusal of a playlist that lists only web addresses.
    static let onlyWebAddresses = "It lists only web addresses, and TextMouth imports only files on this Mac."

    /// The refusal of a playlist with no track left, followed, when entries
    /// were skipped, by what became of them.
    static func noTrack(skipped: [M3UPlaylist.Skipped]) -> String {
        let refusal = "It names no audio file in its own folder that TextMouth can import."
        guard !skipped.isEmpty else { return refusal }
        return "\(refusal) It skipped \(entries(skipped.count)): \(skippedList(skipped))."
    }

    /// The notice of a playlist that imported with entries left out, naming
    /// the playlist; nil when none was skipped.
    static func notice(playlistName: String, skipped: [M3UPlaylist.Skipped]) -> String? {
        guard !skipped.isEmpty else { return nil }
        return "TextMouth skipped \(entries(skipped.count)) of “\(playlistName)”: \(skippedList(skipped))."
    }

    /// `count` entries: "1 entry", "2 entries".
    private static func entries(_ count: Int) -> String {
        CountWording.phrase(count, singular: "entry", plural: "entries")
    }

    /// The skipped entries in playlist order, each as its location in curly
    /// quotes and its reason in parentheses, listed as a sentence lists
    /// them. At most `namedLimit` are named; "and 2 more" counts the rest.
    private static func skippedList(_ skipped: [M3UPlaylist.Skipped]) -> String {
        var items = skipped.prefix(namedLimit).map { "“\($0.location)” (\($0.reason.words))" }
        if skipped.count > namedLimit {
            items.append("\(skipped.count - namedLimit) more")
        }
        return CountWording.list(items)
    }
}
