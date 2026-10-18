import Foundation

/// What can go wrong reading a playlist file, in words a listener hears.
enum M3UPlaylistError: LocalizedError, Equatable {
    /// The playlist file is larger than `M3UPlaylist.maximumByteCount`.
    case tooLarge(fileName: String)

    /// The file name in curly quotation marks, then what is wrong.
    var errorDescription: String? {
        switch self {
        case let .tooLarge(fileName):
            return "The playlist “\(fileName)” is too large to read."
        }
    }
}

/// A playlist in the M3U or M3U8 format (FMT10): a text file that lists audio
/// files, one location per line, with optional `#` directives. This type is
/// the pure part of importing one: `parse` reads the text, and `resolve`
/// decides which of the listed locations are files TextMouth may use.
///
/// TextMouth is not sandboxed, so a playlist could name any file the user can
/// read. Only files inside the playlist's own folder are used, and every
/// entry skipped is named with its reason. A web address is never fetched.
struct M3UPlaylist: Equatable, Sendable {

    /// One listed location, as the playlist spells it.
    struct Entry: Equatable, Sendable {
        /// The line's text, trimmed.
        let location: String
        /// The title the entry's `#EXTINF` line gave it, if any.
        let title: String?
        /// The entry's line in the playlist, counting from 1.
        let line: Int
    }

    /// The playlist's name, from `#PLAYLIST:`.
    var title: String?
    /// The listed locations, in order.
    var entries: [Entry]
    /// Whether the file is an HLS stream (any `#EXT-X-` line) rather than a
    /// list of files.
    var isStreaming: Bool

    /// The extensions (lowercase) of playlist files.
    static let fileExtensions: Set<String> = ["m3u", "m3u8"]

    /// The largest playlist file `read` accepts: 4 MiB.
    static let maximumByteCount = 4 * 1024 * 1024

    /// Whether `url` names a playlist, by its extension in any case.
    static func isPlaylist(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Parsing

    /// The directive prefixes the parser knows (compared without regard to case).
    private enum Directive {
        static let playlist = "#PLAYLIST:"
        static let info = "#EXTINF:"
        static let stream = "#EXT-X-"
    }

    /// The playlist in `text`.
    ///
    /// Lines end at CR, LF, or CRLF. A leading byte-order mark is dropped,
    /// each line is trimmed, and blank lines are skipped. `#PLAYLIST:` names
    /// the playlist; `#EXTINF:` gives the next entry its title; a line starting
    /// `#EXT-X-` marks a stream; any other `#` line is a comment; every other
    /// line is an entry.
    static func parse(_ text: String) -> M3UPlaylist {
        var playlist = M3UPlaylist(title: nil, entries: [], isStreaming: false)
        // The title the last #EXTINF gave, held until an entry takes it.
        var pendingTitle: String?

        let withoutMark = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        // Swift reads CRLF as one Character, so one test per kind of break
        // is enough, and the position in the array is the line's number.
        let lines = withoutMark.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            guard line.hasPrefix("#") else {
                playlist.entries.append(Entry(location: line, title: pendingTitle, line: index + 1))
                pendingTitle = nil
                continue
            }
            if let name = value(of: line, after: Directive.playlist) {
                // A blank name leaves any title already given.
                if let name = nonBlank(name) { playlist.title = name }
            } else if let info = value(of: line, after: Directive.info) {
                pendingTitle = infoTitle(info)
            } else if line.range(of: Directive.stream, options: [.caseInsensitive, .anchored]) != nil {
                playlist.isStreaming = true
            }
            // #EXTM3U and every other # line are ignored.
        }
        return playlist
    }

    /// The text of `line` after `prefix` (matched without regard to case),
    /// trimmed, or nil when the line does not start with it.
    private static func value(of line: String, after prefix: String) -> String? {
        guard let range = line.range(of: prefix, options: [.caseInsensitive, .anchored]) else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` trimmed, or nil when nothing is left.
    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The title in the text after `#EXTINF:` (`<seconds>[ attributes],<title>`):
    /// whatever follows the first comma that is not inside a quoted attribute
    /// value (`tvg-name="a,b"`). Nil when there is no such comma or no title.
    private static func infoTitle(_ info: String) -> String? {
        var insideQuotes = false
        for index in info.indices {
            let character = info[index]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == ",", !insideQuotes {
                return nonBlank(String(info[info.index(after: index)...]))
            }
        }
        return nil
    }

    // MARK: - Reading

    /// The playlist in the file at `url`. The bytes (at most 4 MiB) are
    /// decoded by `TextFileDecoder`: a legacy .m3u in Windows-1252 or Latin 1
    /// reads by its fallback, and an .m3u8 in UTF-8 directly.
    /// - Throws: `M3UPlaylistError.tooLarge` for a larger file, or the error
    ///   reading the file.
    static func read(at url: URL) throws -> M3UPlaylist {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // One byte past the limit is enough to know the file is too large,
        // without reading all of an enormous one.
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw M3UPlaylistError.tooLarge(fileName: url.lastPathComponent)
        }
        let decoded = try TextFileDecoder.decode(data, fileName: url.lastPathComponent, format: .txt)
        return parse(decoded.text)
    }
}

// MARK: - Resolving Entries to Files

extension M3UPlaylist {

    /// An audio file the playlist lists, found inside its folder.
    struct Track: Equatable, Sendable {
        /// The file, with symbolic links resolved.
        let url: URL
        /// The file's path relative to the playlist's folder (`more/tone4.wav`).
        let path: String
        /// The title the playlist gave the entry, if any.
        let title: String?
    }

    /// An entry not used, as the playlist spells it, and why.
    struct Skipped: Equatable, Sendable {
        let location: String
        let reason: SkipReason
    }

    /// Why an entry is not a track.
    enum SkipReason: Equatable, Sendable {
        case webAddress, outsideFolder, missing, folder, notAudio, listedBefore

        /// The reason as a sentence part a listener hears after the entry's name.
        var words: String {
            switch self {
            case .webAddress: return "a web address"
            case .outsideFolder: return "outside the playlist's folder"
            case .missing: return "not found"
            case .folder: return "a folder"
            case .notAudio: return "not an audio file"
            case .listedBefore: return "listed before"
            }
        }
    }

    /// The tracks found and the entries skipped, each in playlist order.
    struct Resolution: Equatable, Sendable {
        var tracks: [Track]
        var skipped: [Skipped]
    }

    /// What an entry's location names, before the disk is asked.
    private enum Location {
        /// A URL with a scheme other than `file:`.
        case webAddress
        /// A path on this Mac, absolute or relative, with slashes.
        case path(String)
        /// A Windows drive path (`C:/Music/x.mp3`).
        case windowsDrive
    }

    /// Whether the playlist lists web addresses and nothing else.
    var listsOnlyWebAddresses: Bool {
        !entries.isEmpty && entries.allSatisfy {
            if case .webAddress = Self.location(of: $0.location) { return true }
            return false
        }
    }

    /// Sort the entries into tracks inside `folder` and skipped entries.
    ///
    /// Each entry, in order, is decided by the first rule that applies:
    /// a web address; a Windows drive path; a path outside the folder (checked
    /// before the disk is asked, so nothing outside is probed); nothing there;
    /// a folder; a file that is not audio; a file an earlier track already is.
    func resolve(inFolder folder: URL, fileManager: FileManager = .default) -> Resolution {
        var resolution = Resolution(tracks: [], skipped: [])
        let canonicalFolder = Self.canonical(folder)
        // Canonical paths of the tracks so far, in Unicode NFC.
        var seen = Set<String>()

        func skip(_ entry: Entry, _ reason: SkipReason) {
            resolution.skipped.append(Skipped(location: entry.location, reason: reason))
        }

        for entry in entries {
            let path: String
            switch Self.location(of: entry.location) {
            case .webAddress: skip(entry, .webAddress); continue
            case .windowsDrive: skip(entry, .outsideFolder); continue
            case let .path(found): path = found
            }

            switch Self.findFile(path, inFolder: canonicalFolder, fileManager: fileManager) {
            case .outside: skip(entry, .outsideFolder)
            case .missing: skip(entry, .missing)
            case let .found(url, isDirectory):
                if isDirectory {
                    skip(entry, .folder)
                } else if !Self.isAudio(url) {
                    skip(entry, .notAudio)
                } else if !seen.insert(url.path.precomposedStringWithCanonicalMapping).inserted {
                    skip(entry, .listedBefore)
                } else {
                    resolution.tracks.append(Track(
                        url: url,
                        path: Self.relativePath(of: url, in: canonicalFolder),
                        title: entry.title))
                }
            }
        }
        return resolution
    }

    // MARK: Classifying a Location

    /// What `location` names. A `file:` URL becomes its path (percent escapes
    /// decoded); backslashes in a path become slashes.
    private static func location(of location: String) -> Location {
        if hasURLScheme(location) {
            // Only a file: URL names a file; every other scheme is the web
            // (or something else this never fetches).
            guard location.lowercased().hasPrefix("file:") else { return .webAddress }
            return .path(URL(string: location)?.path ?? "")
        }
        let slashed = location.replacingOccurrences(of: "\\", with: "/")
        return hasWindowsDrive(slashed) ? .windowsDrive : .path(slashed)
    }

    /// Whether `text` starts with a URL scheme (`https:`): a letter, then one
    /// or more letters, digits, `+`, `.`, or `-`, then a colon. A single
    /// letter and a colon is a Windows drive, not a scheme.
    private static func hasURLScheme(_ text: String) -> Bool {
        var length = 0
        for scalar in text.unicodeScalars {
            if scalar == ":" { return length >= 2 }
            let isLetter = ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
            let isOther = ("0"..."9").contains(scalar) || "+.-".unicodeScalars.contains(scalar)
            guard isLetter || (length > 0 && isOther) else { return false }
            length += 1
        }
        return false
    }

    /// Whether `slashed` (backslashes already slashes) starts with a drive
    /// letter, a colon, and a slash (`C:/`).
    private static func hasWindowsDrive(_ slashed: String) -> Bool {
        let scalars = Array(slashed.unicodeScalars.prefix(3))
        guard scalars.count == 3 else { return false }
        let isLetter = ("A"..."Z").contains(scalars[0]) || ("a"..."z").contains(scalars[0])
        return isLetter && scalars[1] == ":" && scalars[2] == "/"
    }

    // MARK: Finding a File

    /// What the disk says of a path.
    private enum Found {
        case outside
        case missing
        case found(URL, isDirectory: Bool)
    }

    /// The file `path` names for a playlist in `canonicalFolder`. A relative
    /// path is taken from the folder. When nothing is at the path but
    /// something is at its percent-decoded form (`tone%201.wav`), that is used.
    /// A candidate is made canonical (symbolic links resolved), and it must lie
    /// strictly inside the folder, by path components; one that does not is
    /// never asked of the disk. A link inside the folder that points outside
    /// is therefore outside.
    private static func findFile(_ path: String, inFolder canonicalFolder: URL, fileManager: FileManager) -> Found {
        guard !path.isEmpty else { return .missing }
        var spellings = [path]
        if let decoded = path.removingPercentEncoding, decoded != path { spellings.append(decoded) }

        var rawWasOutside = false
        for (index, spelling) in spellings.enumerated() {
            // Built as one absolute path, so no relative URL reaches the disk.
            let base = URL(fileURLWithPath: spelling.hasPrefix("/") ? spelling : canonicalFolder.path + "/" + spelling)
            let candidate = canonical(base)
            guard isInside(candidate, canonicalFolder) else {
                if index == 0 { rawWasOutside = true }
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return .found(candidate, isDirectory: isDirectory.boolValue)
            }
        }
        return rawWasOutside ? .outside : .missing
    }

    /// `url` with symbolic links resolved and `.`/`..` removed.
    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether `url` lies strictly inside `folder` (both canonical), compared
    /// by path components so `/music-extra` is not inside `/music`.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let folderComponents = folder.pathComponents
        let components = url.pathComponents
        return components.count > folderComponents.count && components.starts(with: folderComponents)
    }

    /// `url`'s path relative to `folder` (both canonical, `url` inside).
    private static func relativePath(of url: URL, in folder: URL) -> String {
        url.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/")
    }

    /// Whether `url`'s extension, in any case, is one of the audio formats.
    private static func isAudio(_ url: URL) -> Bool {
        BookFormat.audio.fileExtensions.contains(url.pathExtension.lowercased())
    }
}
