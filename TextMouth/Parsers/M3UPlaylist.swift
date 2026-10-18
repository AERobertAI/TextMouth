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
        case webAddress, outsideFolder, missing, folder, notAudio, hidden, notOrdinaryFile, listedBefore

        /// The reason as a sentence part a listener hears after the entry's name.
        var words: String {
            switch self {
            case .webAddress: return "a web address"
            case .outsideFolder: return "outside the playlist's folder"
            case .missing: return "not found"
            case .folder: return "a folder"
            case .notAudio: return "not an audio file"
            case .hidden: return "hidden"
            case .notOrdinaryFile: return "not an ordinary file"
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
    /// a folder; a file that is not audio; a file that is hidden, or in a
    /// hidden folder; anything but an ordinary file (a FIFO, a socket, a
    /// device); a file an earlier track already is.
    func resolve(inFolder folder: URL, fileManager: FileManager = .default) -> Resolution {
        var resolution = Resolution(tracks: [], skipped: [])
        let resolvedFolder = ResolvedFolder(folder)
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

            switch Self.findFile(path, inFolder: resolvedFolder, fileManager: fileManager) {
            case .outside: skip(entry, .outsideFolder)
            case .missing: skip(entry, .missing)
            case let .found(url, isDirectory):
                if isDirectory {
                    skip(entry, .folder)
                } else if !Self.isAudio(url) {
                    skip(entry, .notAudio)
                } else if let unusable = Self.unusableReason(of: url, inFolder: resolvedFolder.real) {
                    skip(entry, unusable)
                } else if !seen.insert(url.path.precomposedStringWithCanonicalMapping).inserted {
                    skip(entry, .listedBefore)
                } else {
                    resolution.tracks.append(Track(
                        url: url,
                        path: Self.relativePath(of: url, in: resolvedFolder.real),
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

    /// The playlist's folder, spelled two ways. `textual` has its symbolic
    /// links resolved by Foundation, which also drops `/private`; it is the
    /// base of relative entries and the gate that keeps the disk from being
    /// asked about a path that is plainly outside. `real` is the folder as
    /// `realpath(3)` resolves it, and is what every found file is judged by.
    private struct ResolvedFolder {
        let textual: URL
        let real: URL

        /// The two spellings of `folder`. A folder `realpath` cannot resolve
        /// (it is not there) keeps its textual spelling for both, and no
        /// entry in it is found.
        init(_ folder: URL) {
            textual = M3UPlaylist.canonical(folder)
            real = M3UPlaylist.realPath(folder.path) ?? textual
        }
    }

    /// The file `path` names for a playlist in `folder`. A relative path is
    /// taken from the folder. When nothing is at the path but something is at
    /// its percent-decoded form (`tone%201.wav`), that is used.
    ///
    /// Each spelling is judged in two steps. A textual gate (symbolic links
    /// resolved where they exist, `x/..` removed by name) stops a path that
    /// is plainly outside before the disk is asked. Then, once something is
    /// there, the path is resolved fully by `realpath(3)`, which follows
    /// every link, fails on a missing component or a link loop, and so cannot
    /// be fooled by `nothing-here/../extras/diary.m4a` with `extras` a link to
    /// another folder. Only the fully resolved path, strictly inside the
    /// folder by path components, is a file; the found URL is that path.
    private static func findFile(_ path: String, inFolder folder: ResolvedFolder, fileManager: FileManager) -> Found {
        guard !path.isEmpty else { return .missing }
        var spellings = [path]
        if let decoded = path.removingPercentEncoding, decoded != path { spellings.append(decoded) }

        var rawWasOutside = false
        var resolvedWasOutside = false
        for (index, spelling) in spellings.enumerated() {
            // Built as one absolute path, so no relative URL reaches the disk.
            let base = URL(fileURLWithPath: spelling.hasPrefix("/") ? spelling : folder.textual.path + "/" + spelling)
            let candidate = canonical(base)
            guard isInside(candidate, folder.textual) else {
                if index == 0 { rawWasOutside = true }
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }
            // Something is there: resolve it fully before believing where it is.
            guard let real = realPath(candidate.path) else { continue }
            guard isInside(real, folder.real) else {
                resolvedWasOutside = true
                continue
            }
            return .found(real, isDirectory: isDirectory.boolValue)
        }
        return rawWasOutside || resolvedWasOutside ? .outside : .missing
    }

    /// `url` with symbolic links resolved and `.`/`..` removed, by Foundation:
    /// a component that is missing is not an error, and `x/..` is removed by
    /// name. Good for a gate; never proof of where a file is (see `realPath`).
    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// `path` fully resolved by `realpath(3)`: every symbolic link followed,
    /// `.` and `..` applied to the real folders. Nil when a component is
    /// missing, a link loops, or the path has a NUL byte (C would cut it).
    private static func realPath(_ path: String) -> URL? {
        guard !path.unicodeScalars.contains("\0"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Whether `url` lies strictly inside `folder` (both resolved the same
    /// way), compared by path components so `/music-extra` is not inside
    /// `/music`.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let folderComponents = folder.pathComponents
        let components = url.pathComponents
        return components.count > folderComponents.count && components.starts(with: folderComponents)
    }

    // MARK: Ordinary Files

    /// Why the audio file `url` (fully resolved, inside `folder`) cannot be a
    /// track, by the rules the import of a folder applies
    /// (`AudioBookParser.audioFiles(in:)`): nothing hidden, nothing inside a
    /// hidden folder or `__MACOSX`, and regular files only. Nil when it can.
    /// It reads the names and the file system's flags and never opens the
    /// file, which could block forever for a FIFO.
    private static func unusableReason(of url: URL, inFolder folder: URL) -> SkipReason? {
        // The file and every folder between the playlist's folder and it.
        var current = folder
        for component in url.pathComponents.dropFirst(folder.pathComponents.count) {
            current = current.appendingPathComponent(component)
            if isHidden(current) { return .hidden }
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? nil : .notOrdinaryFile
    }

    /// Whether the file or folder at `url` is hidden: a name starting with a
    /// dot, the `__MACOSX` folder of a Mac archive, or the hidden flag.
    private static func isHidden(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name == "__MACOSX" { return true }
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

    /// `url`'s path relative to `folder` (both fully resolved, `url` inside).
    private static func relativePath(of url: URL, in folder: URL) -> String {
        url.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/")
    }

    /// Whether `url`'s extension, in any case, is one of the audio formats.
    private static func isAudio(_ url: URL) -> Bool {
        BookFormat.audio.fileExtensions.contains(url.pathExtension.lowercased())
    }
}
