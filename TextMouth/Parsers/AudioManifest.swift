import Foundation

// MARK: - Manifest

/// Optional JSON manifest for ZIP-based audio books.
/// Placed as manifest.json in the ZIP alongside audio files.
///
/// Every name in a manifest is a track's path relative to the folder that
/// holds the manifest (`AudioManifestLocation`).
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
