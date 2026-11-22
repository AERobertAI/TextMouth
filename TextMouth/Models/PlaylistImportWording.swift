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

    /// What a skipped entry's reason calls a playlist ("outside the
    /// playlist's folder", `M3UPlaylist.SkipReason.words(listedIn:)`); a cue
    /// sheet's names are told as "cue sheet" instead (FMT24).
    static let playlistKind = "playlist" // l10n: no (inside M3UPlaylist's English skip reasons, which a parser words)

    /// The refusal of an HLS stream.
    static var streaming: String {
        // Translators: Refusal of a playlist that is an HLS stream, a list of pieces of one broadcast on the web. "It" is the playlist. Follows the sentence naming the file.
        InterfaceText.line("playlistImport.streaming", "It is a streaming playlist for web audio, which TextMouth does not import.")
    }

    /// The refusal of an XSPF playlist that is no readable XML playlist.
    static func notReadable(fileName: String) -> String {
        // Translators: Refusal of an XSPF playlist that is not a readable XML playlist. %@ is the playlist's file name.
        InterfaceText.line("playlistImport.notReadable", "The playlist “\(fileName)” is not a complete, valid playlist file.")
    }

    /// The refusal of an XSPF playlist that declares XML entities.
    static func declaresEntities(fileName: String) -> String {
        // Translators: Refusal of an XSPF playlist that declares XML entities of its own. %@ is the playlist's file name.
        InterfaceText.line("playlistImport.declaresEntities", "The playlist “\(fileName)” uses XML entities of its own, which TextMouth does not read.")
    }

    /// Whether this build has the Text settings tab where a lexicon is
    /// imported: the Mac does, the iPhone does not.
    static let hasLexiconImport: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// The refusal of a .pls file that is a pronunciation lexicon. With
    /// `advising` (the Mac) it gives the way to use it, naming the button as
    /// the Text settings tab does (`PronunciationLexiconWording.importButton`)
    /// (FMT08); without it (the iPhone, which has no such tab) it ends at
    /// "not a playlist."
    static func pronunciationLexicon(fileName: String, advising: Bool = hasLexiconImport) -> String {
        // Translators: Refusal of a .pls file that is a pronunciation lexicon, not a playlist. %@ is the file's name.
        let refusal = InterfaceText.line("playlistImport.pronunciationLexicon.notPlaylist", "“\(fileName)” is a pronunciation lexicon, not a playlist.")
        guard advising else { return refusal }
        // Translators: Advice after the refusal of a pronunciation lexicon on the Mac. %@ is the title of the import button on the Text tab of Settings, which is another string of the app.
        let advice = InterfaceText.line("playlistImport.pronunciationLexicon.settings", "To use it, choose \(PronunciationLexiconWording.importButton) on the Text tab in Settings.")
        return SentenceWording.joined([refusal, advice])
    }

    /// The refusal of a playlist that lists only web addresses.
    static var onlyWebAddresses: String {
        // Translators: Refusal of a playlist that lists only web addresses. "It" is the playlist. Follows the sentence naming the file.
        InterfaceText.line("playlistImport.onlyWebAddresses", "It lists only web addresses, and TextMouth imports only files on this Mac.")
    }

    /// The refusal of a playlist with no track left, followed, when entries
    /// were skipped, by what became of them. `kind` names the list in a
    /// reason (`M3UPlaylist.SkipReason.words(listedIn:)`): "playlist", or
    /// "cue sheet" for a cue sheet's files (FMT24).
    static func noTrack(
        skipped: [M3UPlaylist.Skipped],
        listedIn kind: String = PlaylistImportWording.playlistKind
    ) -> String {
        // Translators: Refusal of a playlist or cue sheet with no track left to import. "It" is the playlist. A sentence about the skipped entries may follow.
        let refusal = InterfaceText.line("playlistImport.refusal", "It names no audio file in its own folder that TextMouth can import.")
        guard !skipped.isEmpty else { return refusal }
        // Translators: Sentence after the refusal of a playlist: how many entries it skipped, and which. %1$lld is the number of entries and %2$@ the list of them, each with its reason in parentheses.
        let skippedSentence = InterfaceText.line("playlistImport.skippedSentence", "It skipped \(number: skipped.count) entries: \(skippedList(skipped, listedIn: kind)).")
        return SentenceWording.joined([refusal, skippedSentence])
    }

    /// The notice of a playlist that imported with entries left out, naming
    /// the playlist; nil when none was skipped. `kind` names the list in a
    /// reason, as for `noTrack(skipped:listedIn:)`.
    static func notice(
        playlistName: String,
        skipped: [M3UPlaylist.Skipped],
        listedIn kind: String = PlaylistImportWording.playlistKind
    ) -> String? {
        guard !skipped.isEmpty else { return nil }
        // Translators: Notice after a playlist imported with entries left out. %1$lld is the number of entries skipped, %2$@ the playlist's name, and %3$@ the list of the entries, each with its reason in parentheses.
        return InterfaceText.line("playlistImport.skippedEntries", "TextMouth skipped \(number: skipped.count) entries of “\(playlistName)”: \(skippedList(skipped, listedIn: kind)).")
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
    /// location in curly quotes and its reason in parentheses, the list
    /// named as `kind`, listed as a sentence lists them. At most
    /// `namedLimit` are named, and only while the named entries stay within
    /// `listLimit` characters; "and 2 more" counts the rest. The first entry
    /// is always named.
    private static func skippedList(_ skipped: [M3UPlaylist.Skipped], listedIn kind: String) -> String {
        var items: [String] = []
        var length = 0
        // Only the first `namedLimit` entries are ever looked at, however
        // many the playlist skipped.
        for entry in skipped.prefix(namedLimit) {
            // The reason is a parser's English (question 3).
            // Translators: One skipped entry of a playlist in a list: its location in curly quotes, then its reason in parentheses. %1$@ is the location and %2$@ the reason.
            let item = InterfaceText.line("playlistImport.skippedList", "“\(shortened(entry.location))” (\(entry.reason.words(listedIn: kind)))")
            // Two characters for the ", " that joins it to the one before.
            if !items.isEmpty, length + item.count + 2 > listLimit { break }
            items.append(item)
            length += item.count + 2
        }
        if skipped.count > items.count {
            // Translators: Last item of a list of skipped playlist entries, counting the entries not named. %lld is how many more there are.
            items.append(InterfaceText.line("common.countMore", "\(number: skipped.count - items.count) more"))
        }
        return CountWording.list(items)
    }
}
