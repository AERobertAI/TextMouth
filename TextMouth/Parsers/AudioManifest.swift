import Foundation

// MARK: - Manifest

/// Optional JSON manifest for ZIP-based audio books.
/// Placed as manifest.json in the ZIP alongside audio files.
///
/// Every name in a manifest is a track's path relative to the folder that
/// holds the manifest (`AudioManifestLocation`). A book's tracks are
/// arranged by `tracks`, or, in a manifest without it, by `order` and
/// `chapters`, as every manifest arranged them before `tracks` existed
/// (`AudioTrackPlan`); a manifest with `segments`, as the DAISY converter
/// writes, plays stretches of its files as sections instead.
struct AudioManifest: Codable {
    /// Custom title for the audio book
    var title: String?
    /// Author/artist
    var author: String?
    /// Map of filename -> chapter title
    var chapters: [String: String]?
    /// Ordered list of filenames (overrides alphabetical)
    var order: [String]?
    /// Sub-file chapter segments for DAISY and other formats where
    /// chapters are defined as time ranges within audio files rather
    /// than whole-file boundaries. When present, this overrides the
    /// simple one-file-per-chapter model.
    var segments: [AudioSegment]?
    /// The silence, in milliseconds from 0 to 60000, between one track's
    /// end and the next track's start while the book plays on; nil leaves
    /// the default.
    var pauseBetweenTracksMs: Double?
    /// The book's tracks in the order they play, each with the title its
    /// heading shows and the pause after it, and the group headings over
    /// them. Tracks it leaves out follow, in Finder's order. Nil without
    /// the key.
    var tracks: [AudioManifestEntry]?

    /// The keys of a manifest's object, as manifest.json spells them.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case title, author, chapters, order, segments, pauseBetweenTracksMs, tracks
    }

    /// Whether `tracks` arranges the book: it is present, and neither
    /// `order` nor `chapters` is, which arranged books before it. An import
    /// refuses a manifest that has both (`AudioManifestCheck`); one read
    /// later, imported before `tracks` existed, keeps the arrangement it
    /// was imported with.
    var arrangesByTracks: Bool {
        tracks != nil && order == nil && chapters == nil
    }
}

// MARK: - Coding

extension AudioManifest {
    /// Read a manifest as manifest.json stores it. The keys every manifest
    /// has had are read as they always were, so a value of the wrong kind
    /// in one of them fails the whole manifest, which a read then takes for
    /// none (`read(inAudioFolder:)`). `pauseBetweenTracksMs` and `tracks`
    /// are read only when they hold what they should, and as absent
    /// otherwise, so that a manifest read before they existed reads exactly
    /// as it did then. Writing is synthesized, and leaves out every key
    /// whose value is nil, so the manifests the DAISY converter writes are
    /// unchanged. An import checks every key before it reads the book, and
    /// refuses a manifest with any problem (`AudioManifestCheck`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        chapters = try container.decodeIfPresent([String: String].self, forKey: .chapters)
        order = try container.decodeIfPresent([String].self, forKey: .order)
        segments = try container.decodeIfPresent([AudioSegment].self, forKey: .segments)
        pauseBetweenTracksMs = try? container.decodeIfPresent(Double.self, forKey: .pauseBetweenTracksMs)
        tracks = try? container.decodeIfPresent([AudioManifestEntry].self, forKey: .tracks)
    }
}

// MARK: - The Tracks List

/// One entry of a manifest's `tracks` list: a track, or a group heading.
enum AudioManifestEntry: Hashable, Sendable {
    /// A track the book plays.
    case track(AudioManifestTrack)
    /// A group heading: a level-1 heading at the start of the next track,
    /// over the tracks that follow, which then have level-2 headings.
    case heading(String)

    /// The keys of an entry's object, as manifest.json spells them.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case file, title, pauseAfterMs, heading
    }
}

/// A track a manifest's `tracks` list names.
struct AudioManifestTrack: Hashable, Sendable {
    /// The track's path from the folder holding the manifest.
    var file: String
    /// The title the track's heading shows; nil (or a blank title) shows
    /// its file's name without the extension.
    var title: String? = nil
    /// The silence, in milliseconds from 0 to 60000, after the track while
    /// the book plays on; nil takes the manifest's `pauseBetweenTracksMs`.
    var pauseAfterMs: Double? = nil
}

extension AudioManifestEntry: Codable {
    /// Read an entry as manifest.json stores it: a track's file as a
    /// string; or an object with `file`, and optionally `title` and
    /// `pauseAfterMs`; or an object with `heading`, a group heading.
    ///
    /// - Throws: a decoding error for an object with both `file` and
    ///   `heading`, or neither, or a value of the wrong kind; the manifest is
    ///   then read without its tracks list.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let file = try? single.decode(String.self) {
            self = .track(AudioManifestTrack(file: file))
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let file = try container.decodeIfPresent(String.self, forKey: .file)
        let heading = try container.decodeIfPresent(String.self, forKey: .heading)
        switch (file, heading) {
        case (let file?, nil):
            self = .track(AudioManifestTrack(
                file: file,
                title: try container.decodeIfPresent(String.self, forKey: .title),
                pauseAfterMs: try container.decodeIfPresent(Double.self, forKey: .pauseAfterMs)
            ))
        case (nil, let heading?):
            self = .heading(heading)
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "An entry of tracks names a file or a heading, never both or neither."
            ))
        }
    }

    /// Write an entry as it is read: a track with nothing but its file as
    /// the file's name, and anything else as an object holding only the
    /// keys that have values.
    func encode(to encoder: Encoder) throws {
        switch self {
        case .heading(let heading):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(heading, forKey: .heading)
        case .track(let track) where track.title == nil && track.pauseAfterMs == nil:
            var single = encoder.singleValueContainer()
            try single.encode(track.file)
        case .track(let track):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(track.file, forKey: .file)
            try container.encodeIfPresent(track.title, forKey: .title)
            try container.encodeIfPresent(track.pauseAfterMs, forKey: .pauseAfterMs)
        }
    }
}

// MARK: - Arranging the Tracks

/// A folder of tracks arranged as a book, as its manifest says: the tracks
/// in the order they play, each with the title its heading shows, the
/// group heading that begins at it, and its heading's level. The one
/// arrangement the parser makes chapters and headings from.
///
/// A manifest's `tracks` list (`AudioManifest.arrangesByTracks`) gives the
/// order and the titles, and its group headings: each a level-1 heading at
/// the start of the next track listed, under which every track listed after
/// the first group heading has a level-2 heading, while those before it
/// keep level 1. A track the list leaves out follows the listed ones, in
/// Finder's order, with a level-1 heading of its own, outside any group.
/// Without the list, `order` and `chapters` arrange the book exactly as
/// they always have, every heading level 1; without a manifest, the tracks
/// play in Finder's order, each titled by its file's name.
struct AudioTrackPlan: Equatable, Sendable {
    /// One track of the book, in the place it plays.
    struct Track: Equatable, Sendable {
        /// The track's path from the folder holding the manifest, or from
        /// the book's audio folder when it has none.
        let name: String
        /// The title its heading shows.
        let title: String
        /// The group heading that begins at this track, a level-1 heading
        /// before the track's own; nil for a track that begins no group.
        let groupHeading: String?
        /// The level of the track's own heading: 2 under a group heading, 1
        /// otherwise.
        let level: Int
    }

    /// The tracks, in the order the book plays them.
    let tracks: [Track]

    /// `names`, the tracks of a book's folder, each spelled as `manifest`
    /// spells it (from the folder holding the manifest), arranged as
    /// `manifest` says; nil arranges them as a folder without a manifest.
    /// Each track is placed once: a name the manifest gives for a track the
    /// folder does not hold, or gives twice, is passed over, as is a group
    /// heading that is blank, and a group heading with no track listed
    /// after it before the next group heading gives way to that one. An
    /// import refuses every such manifest first (`AudioManifestCheck`);
    /// a manifest changed after the import is still read.
    init(arranging names: [String], by manifest: AudioManifest?) {
        guard let manifest, let entries = manifest.tracks, manifest.arrangesByTracks else {
            // As every book was arranged before the tracks list.
            tracks = AudioBookParser.orderedFileNames(names, manifestOrder: manifest?.order).map { name in
                Track(name: name, title: manifest?.chapters?[name] ?? Self.fileTitle(of: name), groupHeading: nil, level: 1)
            }
            return
        }
        let available = Set(names)
        var listed: [Track] = []
        var placed = Set<String>()
        // The group heading waiting for the next track listed, and whether
        // a group has begun, after which every listed track is in one.
        var waitingHeading: String?
        var groupHasBegun = false
        for entry in entries {
            switch entry {
            case .heading(let heading):
                if let heading = heading.nonBlank {
                    waitingHeading = heading
                }
            case .track(let track):
                guard available.contains(track.file), placed.insert(track.file).inserted else { continue }
                if waitingHeading != nil {
                    groupHasBegun = true
                }
                listed.append(Track(
                    name: track.file,
                    title: track.title?.nonBlank ?? Self.fileTitle(of: track.file),
                    groupHeading: waitingHeading,
                    level: groupHasBegun ? 2 : 1
                ))
                waitingHeading = nil
            }
        }
        let leftOut = AudioBookParser.orderedFileNames(names.filter { !placed.contains($0) }).map { name in
            Track(name: name, title: Self.fileTitle(of: name), groupHeading: nil, level: 1)
        }
        tracks = listed + leftOut
    }

    /// The title a track named `name` shows without one of its own: its
    /// file's name without the extension, whatever folder it is in, as
    /// every track without a title has always shown.
    static func fileTitle(of name: String) -> String {
        ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: - Reading a Manifest

extension AudioManifest {
    /// The name of a manifest's file.
    static let fileName = "manifest.json"

    /// The bytes a UTF-8 byte order mark takes at the start of a file.
    private static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    /// The manifest of the audiobook folder `folder`, found where
    /// `AudioManifestLocation.find(in:)` looks, and read as every read of
    /// the book reads it: nil when the folder has none, and when the one it
    /// has cannot be read or decoded, so that a book whose manifest went
    /// wrong after it was imported still opens, in Finder's order. An import
    /// checks the manifest before it reads the book, and refuses one that
    /// cannot be read, naming the problem (`AudioManifestCheck`).
    static func read(inAudioFolder folder: URL) -> FoundAudioManifest? {
        guard let location = AudioManifestLocation.find(in: folder),
              let data = try? Data(contentsOf: location.url),
              let manifest = try? decoded(from: data) else { return nil }
        return FoundAudioManifest(manifest: manifest, location: location)
    }

    /// `data`, a manifest file's bytes, decoded as a manifest. A UTF-8 byte
    /// order mark at the start, which some editors write, is passed over,
    /// whatever the version of macOS's own JSON reader does with one.
    ///
    /// - Throws: the decoder's error when `data` does not hold a manifest.
    static func decoded(from data: Data) throws -> AudioManifest {
        try JSONDecoder().decode(AudioManifest.self, from: withoutByteOrderMark(data))
    }

    /// `data` without the UTF-8 byte order mark it may start with.
    static func withoutByteOrderMark(_ data: Data) -> Data {
        data.starts(with: utf8ByteOrderMark) ? data.dropFirst(utf8ByteOrderMark.count) : data
    }
}

/// A manifest found in an audiobook's folder, with where it was found,
/// which says how its names are spelled.
struct FoundAudioManifest {
    /// The manifest.
    let manifest: AudioManifest
    /// Where it lies in the audiobook's folder.
    let location: AudioManifestLocation
}

// MARK: - Where the Manifest Lies

/// Where an audiobook folder's manifest.json lies, and so how the tracks it
/// names are spelled: by their paths from the folder holding the manifest.
///
/// The manifest is looked for at the folder's top level, where a ZIP of
/// tracks put beside a manifest by `zip` or by hand leaves it, and, when
/// none is there, inside the folder's one folder: Finder's Compress command
/// puts a folder's contents under the folder's name, so a manifest made
/// beside the tracks lands there.
struct AudioManifestLocation: Equatable, Sendable {
    /// The manifest's file.
    let url: URL
    /// The path from the audiobook's folder to the folder holding the
    /// manifest, ending in a slash: "Radio Dramas/" for a manifest inside a
    /// wrapper folder, or "" for one at the top level. A track the manifest
    /// names lies at this followed by its name.
    let prefix: String

    /// The manifest of the audiobook folder `folder`: manifest.json at its
    /// top level; or, when there is none there and the top level holds
    /// exactly one visible folder and no visible file, manifest.json inside
    /// that folder. Hidden entries, and `__MACOSX`, where Finder keeps the
    /// resource forks of what it compressed, are not counted, as the tracks'
    /// discovery passes over them (`AudioBookParser.audioFiles(in:)`); a
    /// symbolic link is not a folder. Nil when neither place holds one.
    static func find(in folder: URL) -> AudioManifestLocation? {
        let topLevel = folder.appendingPathComponent(AudioManifest.fileName)
        if isFile(topLevel) {
            return AudioManifestLocation(url: topLevel, prefix: "")
        }
        guard let wrapper = onlyVisibleFolder(in: folder) else { return nil }
        let inside = wrapper.appendingPathComponent(AudioManifest.fileName)
        guard isFile(inside) else { return nil }
        return AudioManifestLocation(url: inside, prefix: wrapper.lastPathComponent + "/")
    }

    /// The track at `path`, relative to the audiobook's folder, as the
    /// manifest names it: relative to the folder holding the manifest.
    /// Every track lies inside that folder; a path outside it, which none
    /// has, is given as it is.
    func name(ofTrackAt path: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The path, relative to the audiobook's folder, of the track the
    /// manifest names `name`.
    func path(ofTrackNamed name: String) -> String {
        prefix + name
    }

    /// Whether `url` is a file, or a symbolic link to one: anything but a
    /// folder, which is never a manifest.
    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The one visible entry of `folder`, when it is a folder; nil when
    /// `folder` holds any other visible entry, or none, or cannot be listed.
    private static func onlyVisibleFolder(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let visible = entries.filter { $0.lastPathComponent != "__MACOSX" }
        guard visible.count == 1, let only = visible.first,
              let values = try? only.resourceValues(forKeys: Set(keys)),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return only
    }
}
