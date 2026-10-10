import Foundation

// MARK: - Partial Downloads (FR14)

/// What a download stopped partway leaves on this Mac (FR14): its resume
/// data, in this Mac's resume folder (`FeedDownloadManager.resumeDataFile(for:of:)`),
/// and the partial file that resume data names, which the system keeps in
/// this process's temporary folder so a later download can go on from it.
///
/// Removing the resume data alone would leave that file, the "mp3 parts" the
/// listener asked to have deleted with a cancelled download (October 10:
/// "any in progress downloads should probably be deleted too, like mp3
/// parts"), until the system empties its temporary folder; so every removal
/// of resume data goes through here, and takes the partial file with it.
///
/// Resume data is the system's own, and its layout is not documented: on
/// macOS 10.15 and later it is a keyed archive of a dictionary whose
/// `NSURLSessionResumeInfoTempFileName` names the partial file in the
/// temporary folder (measured on October 10, 2026), and earlier versions
/// wrote the dictionary as a plain property list, naming the file by its
/// path. Rather than decode either, every string the property list holds is
/// read, and only a name the system gives a partial file
/// (`CFNetworkDownload_<letters and digits>.tmp`), taken directly in the
/// temporary folder, is ever removed: resume data that names nothing of the
/// kind, or anything else, removes nothing but itself.
enum FeedPartialDownloads {
    /// What begins the name the system gives a download's partial file.
    static let partialFilePrefix = "CFNetworkDownload_"
    /// What ends that name.
    static let partialFileSuffix = ".tmp"
    /// What ends the name of a resume data file in the resume folder.
    static let resumeDataSuffix = ".resume"

    /// The partial file `resumeData` names, directly in `temporaryFolder`,
    /// when it names one as the system names a download's partial file;
    /// nil for resume data that names none, or is unreadable.
    static func partialFile(namedIn resumeData: Data, temporaryFolder: URL) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: resumeData, format: nil) else { return nil }
        // A name or a path: only its last part is taken, and only in the
        // temporary folder, so no path in the data can reach anywhere else.
        let name = strings(in: plist)
            .map { ($0 as NSString).lastPathComponent }
            .first(where: isPartialFileName)
        return name.map { temporaryFolder.appendingPathComponent($0, isDirectory: false) }
    }

    /// Whether `name` is one the system gives a download's partial file:
    /// its prefix, then letters and digits only, then its suffix.
    static func isPartialFileName(_ name: String) -> Bool {
        guard name.hasPrefix(partialFilePrefix), name.hasSuffix(partialFileSuffix) else { return false }
        let middle = name.dropFirst(partialFilePrefix.count).dropLast(partialFileSuffix.count)
        return !middle.isEmpty && middle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Removes the resume data at `file` and the partial file it names in
    /// `temporaryFolder`, the process's own unless a test gives its own. A
    /// file already gone, or a partial file that is not a plain file, is
    /// left as it is; nothing is reported, since a leftover costs only room
    /// until the system empties its folder.
    static func discard(resumeDataAt file: URL, temporaryFolder: URL = FileManager.default.temporaryDirectory) {
        if let data = try? Data(contentsOf: file),
           let partial = partialFile(namedIn: data, temporaryFolder: temporaryFolder),
           isPlainFile(partial) {
            try? FileManager.default.removeItem(at: partial)
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// Removes every resume data file in `folder` whose name begins with
    /// `prefix` (every one for ""), each with the partial file it names, as
    /// Delete Feed… removes a feed's (FR14), whose names begin with its ID.
    /// - Returns: How many resume data files were removed.
    @discardableResult
    static func discardAll(
        in folder: URL,
        prefix: String = "",
        temporaryFolder: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(resumeDataSuffix) {
            discard(resumeDataAt: folder.appendingPathComponent(name, isDirectory: false), temporaryFolder: temporaryFolder)
            removed += 1
        }
        return removed
    }

    /// Every string `plist` holds, at any depth: a dictionary's values, an
    /// array's elements, and each string itself.
    private static func strings(in plist: Any) -> [String] {
        switch plist {
        case let string as String:
            return [string]
        case let array as [Any]:
            return array.flatMap { strings(in: $0) }
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap { strings(in: $0) }
        default:
            return []
        }
    }

    /// Whether `url` is a plain file, not a folder or a symbolic link, which
    /// a partial file always is.
    private static func isPlainFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
