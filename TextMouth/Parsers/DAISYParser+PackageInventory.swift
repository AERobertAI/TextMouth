import Foundation

// MARK: - DAISY Package Entry Files

/// How TextMouth recognizes a DAISY book kept as loose files: by the file
/// that stands for the whole book at the top of its folder (TODO I02). A
/// DAISY 3 book has a package file (an `.opf`), which lists every file of
/// the book; a DAISY 2.02 book has a navigation file, always named
/// `ncc.html` (or `ncc.htm`), which leads to the rest.
extension DAISYParser {

    /// Whether `name` is a DAISY 2.02 navigation file's name: `ncc.html` or
    /// `ncc.htm`, in any case.
    static func isNCCFileName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased == "ncc.html" || lowercased == "ncc.htm"
    }

    /// Whether `name` is the name of a file that stands for a DAISY book:
    /// a package file (`.opf`) or a navigation file (`ncc.html`).
    static func isPackageEntryName(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "opf" || isNCCFileName(name)
    }

    /// Whether `url` names a file that stands for a DAISY book: its package
    /// file (`.opf`) or its navigation file (`ncc.html`).
    static func isPackageEntryFile(_ url: URL) -> Bool {
        isPackageEntryName(url.lastPathComponent)
    }

    /// The DAISY books whose files fill `directory`, each by the file that
    /// stands for it at the directory's top level: the navigation file when
    /// there is one, since a DAISY 2.02 file set is a single book and the
    /// reader prefers its navigation file (`detectVersion(in:)`); otherwise
    /// every package file, in Finder's name order, each a book of its own.
    ///
    /// Hidden files are never books, so the `._book.opf` copies that macOS
    /// leaves in archives are passed over. Empty when `directory` is not a
    /// directory or holds no book at its top level: a folder whose book lies
    /// in a folder inside it is not itself a book.
    static func packageEntryPoints(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        /// Whether `name` in `directory` is a file, not a folder named like one.
        func isFile(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }

        let entryNames = names
            .filter { !$0.hasPrefix(".") && isPackageEntryName($0) && isFile($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let books = entryNames.first(where: isNCCFileName).map { [$0] } ?? entryNames
        return books.map { directory.appendingPathComponent($0) }
    }

    /// The folders of an archive, whose files `paths` lists, that hold a
    /// DAISY book's package or navigation file at their top level: "" for
    /// the archive's own top level. Hidden entries, and the `__MACOSX`
    /// folder macOS adds to the archives it makes, hold no books.
    static func packageFolders(inArchivePaths paths: [String]) -> Set<String> {
        var folders = Set<String>()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last,
                  isPackageEntryName(name),
                  !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { continue }
            folders.insert(components.dropLast().joined(separator: "/"))
        }
        return folders
    }
}

// MARK: - Reading a Book From Its Entry File

/// Lists one file of a package before all the others, and reads every file
/// as the provider it wraps does. Opened from a package or navigation file,
/// a book is read from that file's whole folder, and the parser takes the
/// first package or navigation file it lists; listing the chosen one first
/// makes that the book the reader chose, even in a folder holding another
/// book's package file beside it (TODO I02).
final class EntryFirstFileProvider: DAISYFileProvider {
    /// The chosen file's path inside the package.
    private let entry: String
    /// The provider that lists and reads the package's files.
    private let inner: DAISYFileProvider

    /// Lists `entry` first among the files `inner` provides.
    init(entry: String, wrapping inner: DAISYFileProvider) {
        self.entry = entry
        self.inner = inner
    }

    /// Every file `inner` lists, `entry` first when it is among them.
    func listFiles() -> [String] {
        let files = inner.listFiles()
        guard files.contains(entry) else { return files }
        return [entry] + files.filter { $0 != entry }
    }

    /// The file at `path`, as `inner` reads it.
    func readFile(at path: String) throws -> Data {
        try inner.readFile(at: path)
    }
}
