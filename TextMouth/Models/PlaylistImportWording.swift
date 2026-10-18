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

    /// The most characters one named entry keeps (its location, before the
    /// curly quotes and the reason).
    static let entryLimit = 60

    /// The most characters a file name keeps in a shortened entry; a longer
    /// one loses its middle.
    static let fileNameLimit = 40

    /// The most characters the whole list of named entries spans, so a
    /// playlist of long lines cannot make an alert too long to listen to.
    static let listLimit = 600

    /// `location` as at most `entryLimit` characters. A longer one keeps its
    /// start and its file name (from its last slash or backslash on), joined by
    /// "…": "Music/Audiobooks/A Very…/03 Intro.mp3". A file name of more
    /// than `fileNameLimit` characters is itself shortened in its middle,
    /// to its first 20 and its last 19 characters around "…". An entry of
    /// `entryLimit` characters or fewer is kept whole.
    static func shortened(_ location: String) -> String {
        guard location.count > entryLimit else { return location }
        // The tail is the last separator and the file name after it; with no
        // separator the whole entry is the file name and has no start.
        let separatorIndex = location.lastIndex { $0 == "/" || $0 == "\\" }
        let fileName = separatorIndex.map { String(location[location.index(after: $0)...]) } ?? location
        let shortName = fileName.count > fileNameLimit
            ? "\(fileName.prefix(20))…\(fileName.suffix(19))"
            : fileName
        guard let separatorIndex else { return shortName }
        let tail = "\(location[separatorIndex])\(shortName)"
        // The start fills what the tail and the joining "…" leave of the limit.
        let startLength = max(0, entryLimit - tail.count - 1)
        return "\(location.prefix(startLength))…\(tail)"
    }

    /// The skipped entries in playlist order, each as its (shortened)
    /// location in curly quotes and its reason in parentheses, listed as a
    /// sentence lists them. At most `namedLimit` are named, and only while
    /// the named entries stay within `listLimit` characters; "and 2 more"
    /// counts the rest. The first entry is always named.
    private static func skippedList(_ skipped: [M3UPlaylist.Skipped]) -> String {
        var items: [String] = []
        var length = 0
        // Only the first `namedLimit` entries are ever looked at, however
        // many the playlist skipped.
        for entry in skipped.prefix(namedLimit) {
            let item = "“\(shortened(entry.location))” (\(entry.reason.words))"
            // Two characters for the ", " that joins it to the one before.
            if !items.isEmpty, length + item.count + 2 > listLimit { break }
            items.append(item)
            length += item.count + 2
        }
        if skipped.count > items.count {
            items.append("\(skipped.count - items.count) more")
        }
        return CountWording.list(items)
    }
}
