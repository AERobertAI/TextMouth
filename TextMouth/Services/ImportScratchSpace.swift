import Foundation

/// Where imports keep the folders they throw away (FR02): the directories
/// they extract archives into (`ArchiveExtractionDirectory`) and the
/// packages they build before publishing them (`ImportStaging`).
///
/// While the data directory is on the volume that holds this Mac's own
/// TextMouth folder (`MachineLocalPaths.root`), both are kept there, outside
/// the data directory: a data directory in a cloud folder then never uploads
/// throwaway data, and another Mac's import never meets this Mac's leftovers
/// or has its own taken for them. Publishing a staged package is still one
/// rename into the library folder, on the same volume; iCloud Drive and File
/// Provider folders are on the startup volume too. While the data directory
/// is on another volume, both stay in it, as before, so publishing never
/// crosses volumes, and the free-space check of an extraction speaks for the
/// disk the books go to either way.
enum ImportScratchSpace {
    /// Whether the items at two locations are on one volume.
    typealias VolumeComparison = (URL, URL) -> Bool

    /// Whether imports keep their throwaway folders on this Mac: whether the
    /// data directory `dataDirectory` is on the volume of this Mac's own
    /// folder `machineLocalRoot`, as `sameVolume` tells. Tests pass their
    /// own comparison.
    static func isOnThisMac(
        dataDirectory: URL = TextMouthPaths.root,
        machineLocalRoot: URL = MachineLocalPaths.root,
        sameVolume: VolumeComparison = areOnSameVolume
    ) -> Bool {
        sameVolume(dataDirectory, machineLocalRoot)
    }

    /// Whether the items at `first` and `second`, or the nearest folders
    /// above them that exist, are on one volume, by their volume
    /// identifiers. False when either volume cannot be told, so a scratch
    /// folder whose volume is in doubt stays beside the books it is for.
    static func areOnSameVolume(_ first: URL, _ second: URL) -> Bool {
        guard let firstVolume = volumeIdentifier(of: first),
              let secondVolume = volumeIdentifier(of: second) else { return false }
        return firstVolume.isEqual(secondVolume)
    }

    /// The identifier of the volume holding `location`, or the nearest
    /// folder above it that exists; nil when none can be read. Read with
    /// dataless files left in the cloud: only metadata is needed.
    private static func volumeIdentifier(of location: URL) -> NSObjectProtocol? {
        DatalessFiles.withoutDownloading {
            var existing = location.standardizedFileURL
            while !FileManager.default.fileExists(atPath: existing.path) {
                let parent = existing.deletingLastPathComponent()
                guard parent.path != existing.path else { return nil }
                existing = parent
            }
            return (try? existing.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        }
    }

    // MARK: - The Folders

    /// The folder archives are extracted in: this Mac's Archive Extraction
    /// folder (`MachineLocalPaths.archiveExtraction`) when `onThisMac`, and
    /// otherwise the data directory's own (`inLibraryArchiveExtraction`).
    static func archiveExtractionFolder(onThisMac: Bool = isOnThisMac()) -> URL {
        onThisMac ? MachineLocalPaths.archiveExtraction : inLibraryArchiveExtraction
    }

    /// The Archive Extraction folder of the data directory, where earlier
    /// versions extracted archives, and where extraction happens while the
    /// data directory is on another volume than this Mac's folder.
    static var inLibraryArchiveExtraction: URL {
        TextMouthPaths.root.appendingPathComponent(ArchiveExtractionDirectory.folderName, isDirectory: true)
    }

    /// The folder a package to be published at `destination` is staged in:
    /// this Mac's Import Staging folder (`MachineLocalPaths.importStaging`)
    /// when `onThisMac` and the destination is in the data directory, and
    /// otherwise the folder `destination` is in, as before.
    static func stagingFolder(publishingTo destination: URL, onThisMac: Bool = isOnThisMac()) -> URL {
        let isInDataDirectory = StorageBoundary.shared.current.location.contains(destination.path)
        return onThisMac && isInDataDirectory
            ? MachineLocalPaths.importStaging
            : destination.deletingLastPathComponent()
    }

    /// Creates the scratch folder `folder`, with the folders above it, when
    /// it is not there yet, and keeps it out of Time Machine backups, since
    /// what it holds lasts only as long as an import. Failing to keep it out
    /// of backups is harmless.
    static func prepareFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    // MARK: - Logging

    /// How a log line names the item at `url`: by its path inside this
    /// Mac's TextMouth folder, such as "Archive Extraction/extract-…", which
    /// says which folder it was in without naming the user's home; and
    /// anywhere else as `DiagnosticLog.loggablePath(_:)` names it.
    static func loggablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for prefix in DiagnosticLog.dataDirectoryPrefixes(of: MachineLocalPaths.root) where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return DiagnosticLog.loggablePath(path)
    }
}
