import Foundation

/// PLS and XSPF playlists, read into the same `M3UPlaylist` an M3U file
/// makes (FMT12), so the import that follows (`resolve(inFolder:)` and the
/// book of tracks) is one and the same for all three, with the same rule for
/// a file outside the playlist's folder and for a web address.
///
/// - PLS is an INI file: `File1=`, `Title1=`, `Length1=`. Entries are taken
///   in the order of their numbers. It names no playlist, so the book takes
///   its file's name.
/// - XSPF is XML: a `trackList` of `track`s, each with a `location` (a URI,
///   resolved against `xml:base` when it has one) and a `title`; the
///   playlist's own `title` names the book.
extension M3UPlaylist {

    // MARK: - PLS

    /// The playlist in the PLS `text`.
    ///
    /// Lines end at CR, LF, or CRLF; a leading byte-order mark is dropped.
    /// A line `FileN=location` is an entry and `TitleN=text` its title, with
    /// keys in any capitals; `[playlist]`, `Length`, `NumberOfEntries`,
    /// `Version`, `;` comments, and anything else are ignored. Entries are
    /// ordered by N (a repeated N keeps the first), whatever order the lines
    /// are in, and an entry's `line` is the line of its `File` key.
    static func parsePLS(_ text: String) -> M3UPlaylist {
        var locations: [Int: (location: String, line: Int)] = [:]
        var titles: [Int: String] = [:]

        let withoutMark = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = withoutMark.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // A comment, a section header, or a line with no key and value.
            guard !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let number = numberedKey(key, prefix: "file") {
                if !value.isEmpty, locations[number] == nil { locations[number] = (value, index + 1) }
            } else if let number = numberedKey(key, prefix: "title") {
                if !value.isEmpty, titles[number] == nil { titles[number] = value }
            }
        }
        let entries = locations.keys.sorted().map { number in
            Entry(location: locations[number]!.location, title: titles[number], line: locations[number]!.line)
        }
        return M3UPlaylist(title: nil, entries: entries, isStreaming: false)
    }

    /// The number in `key` when it is `prefix` followed by digits alone
    /// (`file12`), else nil. Digits too many to be a number are no number.
    private static func numberedKey(_ key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        let digits = key.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// Whether `text` is XML (its first character, after white space, is
    /// `<`), which a PLS playlist never is: a W3C pronunciation lexicon also
    /// uses the extension .pls (FMT08).
    static func looksLikeXML(_ text: String) -> Bool {
        text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).first == "<"
    }

    // MARK: - XSPF

    /// The most tracks taken from one XSPF playlist.
    static let xspfTrackLimit = 100_000

    /// The playlist in the XSPF `data`.
    /// - Throws: `M3UPlaylistError.declaresEntities` when it declares an XML
    ///   entity, and `M3UPlaylistError.notReadable` when it is not XML, is cut
    ///   off, or its root is not a `playlist`.
    static func parseXSPF(_ data: Data, fileName: String) throws -> M3UPlaylist {
        let reader = XSPFReader()
        let parser = XMLParser(data: data)
        // An XSPF playlist never needs an external entity, and resolving one
        // would read a file or a web address a hostile playlist names.
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let finished = parser.parse()
        // A declared entity would be read as nothing, silently: refuse it.
        if reader.declaresEntities { throw M3UPlaylistError.declaresEntities(fileName: fileName) }
        guard !reader.rootWasNotAPlaylist, finished || reader.reachedTrackLimit else {
            throw M3UPlaylistError.notReadable(fileName: fileName)
        }
        return M3UPlaylist(title: reader.title, entries: reader.entries, isStreaming: false)
    }
}

/// Reads an XSPF playlist's title and tracks off an `XMLParser`, whatever
/// namespace prefix its elements have, and ignoring every element it does
/// not know (`creator`, `duration`, `extension`).
private final class XSPFReader: EntityRefusingXMLReader {
    /// The playlist's own title.
    private(set) var title: String?
    /// The tracks read, as entries.
    private(set) var entries: [M3UPlaylist.Entry] = []
    /// Whether the document's root element is not a `playlist`.
    private(set) var rootWasNotAPlaylist = false
    /// Whether reading stopped at `M3UPlaylist.xspfTrackLimit`.
    private(set) var reachedTrackLimit = false

    /// The names of the open elements, outermost first, lowercased.
    private var path: [String] = []
    /// The `xml:base` in force at each open element, outermost first, so a
    /// track's own base overrides the playlist's while it is open.
    private var bases: [String?] = []
    /// The text collected for the element being read, if it is one we keep.
    private var text: String?
    /// The first location, title, and line of the track being read.
    private var location: String?
    private var trackTitle: String?
    private var trackLine = 0
    /// The base the track being read resolves its location against.
    private var trackBase: String?

    /// An element's name without a namespace prefix, in lowercase.
    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = local(elementName)
        path.append(name)
        // The base in force: this element's own, else its parent's.
        let inheritedBase: String? = bases.last ?? nil
        bases.append(attributeDict["xml:base"] ?? inheritedBase)
        if path.count == 1 {
            // Only a playlist is read; any other root stops the parse.
            if name != "playlist" {
                rootWasNotAPlaylist = true
                parser.abortParsing()
            }
            return
        }
        switch path {
        case ["playlist", "title"], ["playlist", "tracklist", "track", "location"],
             ["playlist", "tracklist", "track", "title"]:
            text = ""
        case ["playlist", "tracklist", "track"]:
            location = nil
            trackTitle = nil
            trackLine = parser.lineNumber
            trackBase = bases.last ?? nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text? += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            path.removeLast()
            bases.removeLast()
        }
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case ["playlist", "title"]:
            if title == nil, let value, !value.isEmpty { title = value }
            text = nil
        case ["playlist", "tracklist", "track", "location"]:
            // A track may list several locations; the first is the one used.
            if location == nil, let value, !value.isEmpty { location = value }
            text = nil
        case ["playlist", "tracklist", "track", "title"]:
            if trackTitle == nil, let value, !value.isEmpty { trackTitle = value }
            text = nil
        case ["playlist", "tracklist", "track"]:
            // A track with no location names nothing to import.
            if let location {
                entries.append(M3UPlaylist.Entry(
                    location: Self.resolved(location, against: trackBase),
                    title: trackTitle,
                    line: trackLine
                ))
                if entries.count >= M3UPlaylist.xspfTrackLimit {
                    reachedTrackLimit = true
                    parser.abortParsing()
                }
            }
        default:
            break
        }
    }

    /// `location` made absolute against `base` when both are there and the
    /// location is relative (no scheme and no leading slash); otherwise the
    /// location as written. A base that is a web address makes a web
    /// address, and one that is a folder elsewhere makes a path the
    /// playlist's resolver finds outside its folder.
    private static func resolved(_ location: String, against base: String?) -> String {
        guard let base, !base.isEmpty,
              !location.hasPrefix("/"), !location.contains(":"),
              let baseURL = URL(string: base),
              let absolute = URL(string: location, relativeTo: baseURL)?.absoluteString else {
            return location
        }
        return absolute
    }
}
