import CryptoKit
import Foundation
import SwiftSoup

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
            .sortedStably { $0.localizedStandardCompare($1) == .orderedAscending }
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

// MARK: - Package Errors

/// Why a DAISY book kept as loose files cannot be imported with its files
/// (TODO I02).
enum DAISYPackageError: LocalizedError, Equatable {
    /// A file of the book refers to `reference`, which lies outside the
    /// book's folder, or is a symbolic link leading out of it. `file` is the
    /// referring file's path inside the folder.
    case referenceOutsidePackage(reference: String, file: String)
    /// A folder holds no DAISY book: no navigation file and no package file
    /// at its top level. Also a file chosen as a book's that is neither.
    case notAPackage
    /// A folder's top level holds several books' package files, named here,
    /// so the folder names no one book.
    case severalPackages([String])

    var errorDescription: String? {
        switch self {
        case let .referenceOutsidePackage(reference, file):
            return "The file “\(file)” in this DAISY book refers to “\(reference)”, which is outside the book's "
                + "folder. Only files inside the folder can be imported."
        case .notAPackage:
            return "The folder is not a DAISY book: it has no ncc.html or .opf file at its top level."
        case .severalPackages(let names):
            return "The folder holds \(names.count) DAISY books (\(names.joined(separator: ", "))). "
                + "Import each book's .opf file on its own."
        }
    }
}

// MARK: - Package Inventory

/// The files a DAISY book kept as loose files needs, found from the file
/// that stands for it, so that an import copies the book and nothing else
/// (TODO I02).
///
/// The book's folder is its package root, and every file is named by its
/// path inside that folder. A DAISY 3 book needs its package file and every
/// file its manifest lists. A DAISY 2.02 book needs its navigation file,
/// every SMIL file the navigation links to, every text and audio file those
/// SMIL files synchronize, and every style sheet and image the navigation
/// and text files use. References are resolved as the reader resolves them,
/// relative to the file that makes them. One that leads out of the folder,
/// directly or through a symbolic link, is an error naming it, so nothing
/// outside the folder is ever copied. A file referred to that does not
/// exist is noted and left out: the book reads without it as it did before.
///
/// When the files cannot be listed, because a file that lists them is
/// damaged or because a DAISY 3 manifest names no DTBook (the reader then
/// searches the whole folder for one), the inventory is the whole folder,
/// and reading the copied book decides whether the import succeeds, naming
/// any damaged file. Hidden files are never part of a book, and neither are
/// the files TextMouth keeps at the top of its own packages, so the
/// inventory of a book's copy in the library is the book's own inventory.
struct DAISYPackageInventory {
    /// One file of the book.
    struct File: Equatable {
        /// Its path inside the book's folder, with "/" between folders.
        let path: String
        /// Where it is read from: inside the folder, with symbolic links
        /// resolved, so a copy is always of the file itself.
        let source: URL
        /// Its size in bytes.
        let size: Int
    }

    /// The book's folder.
    let root: URL
    /// The path, inside `root`, of the file that stands for the book (its
    /// OPF or ncc.html), which always lies at the folder's top level.
    let entryPath: String
    /// Every file of the book, the entry file included, ordered by path
    /// (the code-point order of the paths' Unicode NFC forms).
    let files: [File]
    /// The paths of files the book refers to that do not exist, in order.
    let missingPaths: [String]
    /// Why the whole folder was taken because the book's files could not
    /// be listed from its references, or nil when they were.
    let wholeFolderReason: String?

    /// Builds an inventory, putting `files` in path order.
    private init(root: URL, entryPath: String, files: [File], missingPaths: [String], wholeFolderReason: String?) {
        self.root = root
        self.entryPath = entryPath
        self.files = files.sortedStably { Self.pathPrecedes($0.path, $1.path) }
        self.missingPaths = missingPaths.sortedStably { Self.pathPrecedes($0, $1) }
        self.wholeFolderReason = wholeFolderReason
    }

    /// The file that stands for the book.
    var entryURL: URL { root.appendingPathComponent(entryPath) }

    /// The paths of the book's files, in order.
    var paths: [String] { files.map(\.path) }

    /// The name a book whose files give it no title is listed under, when
    /// its entry file's own name would not do: every DAISY 2.02 navigation
    /// file is named ncc.html, so the book's folder names it instead. Nil
    /// for a package file, whose name already names its book.
    var untitledName: String? {
        DAISYParser.isNCCFileName(entryPath) ? root.lastPathComponent : nil
    }

    // MARK: Finding a Book's Files

    /// The inventory of the DAISY book kept as loose files that `source`,
    /// an item chosen for import, is: a folder with the book's file at its
    /// top level, or that file (an OPF or ncc.html) inside its folder. Nil
    /// for any other item, a DAISY ZIP or a TextMouth package included,
    /// which is imported as the single item it is.
    /// - Throws: as `make(for:)`.
    static func ofSource(_ source: URL) throws -> DAISYPackageInventory? {
        guard source.pathExtension.lowercased() != "tmb",
              isDirectory(source) || DAISYParser.isPackageEntryFile(source) else { return nil }
        return try make(for: source)
    }

    /// The inventory of the book `url` stands for: a folder holding one
    /// DAISY book at its top level, or the book's OPF or ncc.html.
    /// - Throws: `DAISYPackageError.notAPackage` for a folder without a
    ///   book, or a file that does not stand for one; `.severalPackages`
    ///   for a folder of several books; `.referenceOutsidePackage`, naming
    ///   the reference and the file making it, for a reference that leads
    ///   out of the book's folder; and the error reading the entry file or
    ///   a file it leads to, when one cannot be read.
    static func make(for url: URL) throws -> DAISYPackageInventory {
        let entry = try entryFile(for: url)
        let root = entry.deletingLastPathComponent()
        let entryPath = entry.lastPathComponent

        // The entry file is added by its name, not read as a reference: a
        // file name may hold "#", "%", or ":", which a reference gives
        // other meanings.
        var collector = PackageFileCollector(root: root)
        try collector.addPath(entryPath, referredToAs: entryPath, in: entryPath)
        let entryData = try Data(contentsOf: collector.source(of: entryPath) ?? entry)
        let wholeFolderReason: String?
        if DAISYParser.isNCCFileName(entryPath) {
            wholeFolderReason = try collectNavigationFiles(from: entryData, of: entryPath, into: &collector)
        } else {
            wholeFolderReason = try collectManifestFiles(from: entryData, of: entryPath, into: &collector)
        }

        guard let wholeFolderReason else {
            return DAISYPackageInventory(
                root: root,
                entryPath: entryPath,
                files: collector.files,
                missingPaths: collector.missingPaths,
                wholeFolderReason: nil
            )
        }
        return DAISYPackageInventory(
            root: root,
            entryPath: entryPath,
            files: try wholeFolderFiles(in: root),
            missingPaths: [],
            wholeFolderReason: wholeFolderReason
        )
    }

    /// The file that stands for the book `url` names: `url` itself when it
    /// is an OPF or ncc.html, or the one such file at the top of the folder
    /// `url`.
    private static func entryFile(for url: URL) throws -> URL {
        guard isDirectory(url) else {
            guard DAISYParser.isPackageEntryFile(url) else { throw DAISYPackageError.notAPackage }
            return url
        }
        let entries = DAISYParser.packageEntryPoints(in: url)
        guard let entry = entries.first else { throw DAISYPackageError.notAPackage }
        guard entries.count == 1 else {
            throw DAISYPackageError.severalPackages(entries.map(\.lastPathComponent))
        }
        return entry
    }

    // MARK: Checksum and Copy

    /// The checksum a book imported from this package is known by, which
    /// duplicate detection compares (TODO I02). It is the MD5 digest, in
    /// lowercase hexadecimal, of this text in UTF-8:
    ///
    /// 1. the MD5 digest of the entry file (the OPF or ncc.html), in
    ///    lowercase hexadecimal; then
    /// 2. for each file of the inventory, the entry file included, in the
    ///    code-point order of their paths: a NUL character, the file's path
    ///    inside the book's folder (Unicode NFC, "/" between folders), a NUL
    ///    character, and the file's size in bytes, in decimal.
    ///
    /// Two copies of a book therefore share the checksum wherever they lie,
    /// its copy in the library included, while any change to the entry
    /// file, and adding, removing, renaming, or resizing any file of the
    /// book, changes it. A file whose bytes change but not its size leaves
    /// it as it was: reading every audio file of a long book would take
    /// minutes.
    func contentHash() throws -> String {
        var text = try FileImportService.md5Hash(of: files.first { $0.path == entryPath }?.source ?? entryURL)
        let ordered = files
            .map { (path: $0.path.precomposedStringWithCanonicalMapping, size: $0.size) }
            .sortedStably { Self.pathPrecedes($0.path, $1.path) }
        for file in ordered {
            text += "\u{0}\(file.path)\u{0}\(file.size)"
        }
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    /// Copies every file of the book into `directory` at its path inside
    /// the book's folder, creating folders on the way, and returns where
    /// the entry file landed. A file already there is left as it is: two
    /// references can name one file in different letter case, which a
    /// volume that ignores case stores once.
    @discardableResult
    func copyFiles(into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        for file in files {
            let destination = directory.appendingPathComponent(file.path)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: file.source, to: destination)
        }
        return directory.appendingPathComponent(entryPath)
    }

    // MARK: References

    /// The path inside the book's folder that `reference`, made in the
    /// book's file `file`, names: relative to that file's folder, with "."
    /// and ".." applied and percent escapes decoded, as the reader resolves
    /// it (`ParserUtilities.resolvedPackagePath`), and from the folder's top
    /// when it starts with "/". Nil for a reference to no file of the book:
    /// an empty one, a fragment of `file` itself, the folder itself, or an
    /// address with a scheme of its own, such as a web page.
    /// - Throws: `DAISYPackageError.referenceOutsidePackage` naming
    ///   `reference` when it climbs above the book's folder, which the
    ///   reader would not, or names a file elsewhere on the computer
    ///   (`file:`).
    static func packagePath(of reference: String, in file: String) throws -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = urlScheme(of: trimmed) {
            guard scheme == "file" else { return nil }
            throw DAISYPackageError.referenceOutsidePackage(reference: reference, file: file)
        }
        let path = ParserUtilities.splitFragment(trimmed).path
        guard !path.isEmpty else { return nil }

        var components = path.hasPrefix("/") ? [] : file.split(separator: "/").dropLast().map(String.init)
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw DAISYPackageError.referenceOutsidePackage(reference: reference, file: file)
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// The scheme `reference` starts with, lowercased ("http" for
    /// "http://…"), or nil when it is a path. As in a URL, a scheme is a
    /// letter followed by letters, digits, "+", "-", or ".", then ":".
    private static func urlScheme(of reference: String) -> String? {
        guard let colon = reference.firstIndex(of: ":") else { return nil }
        let scheme = reference[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return nil
        }
        return scheme.lowercased()
    }

    /// Whether `path` can be a file of a book: no part of it is hidden, and
    /// it is not one of the files TextMouth keeps at the top of its
    /// packages (its record, text cache, audio cache, and removal marker).
    static func isBookPath(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let top = components.first, FileImportService.isPackageContentName(String(top)) else { return false }
        return !components.contains { $0.hasPrefix(".") }
    }

    /// Whether `first` comes before `second` in the code-point order of
    /// their Unicode NFC forms, the one order a book's files are listed and
    /// hashed in wherever they lie.
    private static func pathPrecedes(_ first: String, _ second: String) -> Bool {
        first.precomposedStringWithCanonicalMapping.utf8
            .lexicographicallyPrecedes(second.precomposedStringWithCanonicalMapping.utf8)
    }

    /// Whether `url` is a folder, following a symbolic link to one.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: DAISY 3

    /// Adds every file a DAISY 3 package file's manifest lists. Returns why
    /// the whole folder must be taken instead, or nil.
    private static func collectManifestFiles(
        from data: Data,
        of entryPath: String,
        into collector: inout PackageFileCollector
    ) throws -> String? {
        let package: DAISYOPFResult
        do {
            package = try DAISYOPFParser(data: data, file: entryPath).parse()
        } catch {
            return error.localizedDescription
        }
        // With no DTBook in its manifest, the reader searches the whole
        // folder for one (`DAISYParser.extractMarkdown`), so the copy must
        // hold everything that search would see.
        guard package.manifest.values.contains(where: { $0.mediaType.contains("dtbook") }) else {
            return "the manifest of “\(entryPath)” lists no DTBook content file"
        }
        for href in package.manifest.values.map(\.href).sortedStably() {
            try collector.add(href, in: entryPath)
        }
        return nil
    }

    // MARK: DAISY 2.02

    /// Adds every file a DAISY 2.02 navigation file leads to: the SMIL
    /// files its links name, the text and audio files they synchronize,
    /// and the style sheets and images of the navigation and text files.
    /// Returns why the whole folder must be taken instead, or nil.
    private static func collectNavigationFiles(
        from data: Data,
        of entryPath: String,
        into collector: inout PackageFileCollector
    ) throws -> String? {
        let html = decodedText(data)
        let navigation: SwiftSoup.Document
        do {
            // Read as the reader reads it first, so a copy cut short counts
            // as damaged here as well.
            _ = try DAISY202NCCParser(html: html, file: entryPath).parse()
            navigation = try MarkupGuard.parse(html)
        } catch {
            return error.localizedDescription
        }
        try collectStyleSheetsAndImages(in: navigation, of: entryPath, into: &collector)

        // Every SMIL file a link names: the headings' links, which the
        // reader follows, and any other, such as a page number's.
        var smilPaths: [String] = []
        var seenSMIL: Set<String> = []
        try forEachElement(under: navigation) { element in
            guard element.tagName().lowercased() == "a",
                  let href = try? element.attr("href"), !href.isEmpty,
                  let path = try collector.add(href, in: entryPath),
                  path.lowercased().hasSuffix(".smil"),
                  seenSMIL.insert(path).inserted else { return }
            smilPaths.append(path)
        }

        var textPaths: [String] = []
        var seenText: Set<String> = []
        for smilPath in smilPaths {
            // A missing SMIL file is passed over, as the reader passes it over.
            guard let smil = collector.source(of: smilPath) else { continue }
            let smilData = try Data(contentsOf: smil)
            let textReferences: [String]
            let audioClips: [DAISYAudioClip]
            do {
                textReferences = try DAISYSMILParser(data: smilData, file: smilPath).parseTextReferences()
                audioClips = try DAISYAudioSMILParser(data: smilData, file: smilPath).parse()
            } catch {
                return error.localizedDescription
            }
            for reference in textReferences {
                if let path = try collector.add(reference, in: smilPath), seenText.insert(path).inserted {
                    textPaths.append(path)
                }
            }
            for clip in audioClips {
                try collector.add(clip.file, in: smilPath)
            }
        }

        for textPath in textPaths {
            guard let text = collector.source(of: textPath) else { continue }
            let textData = try Data(contentsOf: text)
            let document: SwiftSoup.Document
            do {
                document = try MarkupGuard.parse(decodedText(textData))
            } catch {
                return error.localizedDescription
            }
            try collectStyleSheetsAndImages(in: document, of: textPath, into: &collector)
        }
        return nil
    }

    /// Adds the style sheets and images the HTML document `document`, the
    /// book's file `file`, uses: each `<link rel="stylesheet">` and `<img>`.
    private static func collectStyleSheetsAndImages(
        in document: SwiftSoup.Node,
        of file: String,
        into collector: inout PackageFileCollector
    ) throws {
        try forEachElement(under: document) { element in
            let reference: String?
            switch element.tagName().lowercased() {
            case "link":
                let relations = ((try? element.attr("rel")) ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                reference = relations.contains("stylesheet") ? (try? element.attr("href")) : nil
            case "img":
                reference = try? element.attr("src")
            default:
                reference = nil
            }
            if let reference, !reference.isEmpty {
                try collector.add(reference, in: file)
            }
        }
    }

    /// Calls `visit` with every element under `node`, in document order. A
    /// direct walk keeps SwiftSoup's selector cache, which would hold on to
    /// each document, out of these one-time reads, as `DAISY202NCCParser`
    /// does.
    private static func forEachElement(
        under node: SwiftSoup.Node,
        _ visit: (SwiftSoup.Element) throws -> Void
    ) rethrows {
        for child in node.getChildNodes() {
            guard let element = child as? SwiftSoup.Element else { continue }
            try visit(element)
            try forEachElement(under: element, visit)
        }
    }

    /// `data` decoded as the reader decodes DAISY 2.02 files: as UTF-8 when
    /// it is valid UTF-8, otherwise as ISO Latin 1, which decodes any bytes.
    private static func decodedText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Whole Folder

    /// Every file of the book's folder, for a book whose files cannot be
    /// listed from its references: all but hidden files and TextMouth's own
    /// package files (`isBookPath(_:)`), skipping any symbolic link that
    /// leads out of the folder.
    private static func wholeFolderFiles(in root: URL) throws -> [File] {
        let fileManager = FileManager.default
        guard let entries = fileManager.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var files: [File] = []
        while let path = entries.nextObject() as? String {
            // The enumerator's attributes describe a symbolic link itself,
            // so a link to a folder is never entered.
            let isFolder = (entries.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            guard isBookPath(path) else {
                if isFolder { entries.skipDescendants() }
                continue
            }
            guard !isFolder else { continue }
            let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(resolvedRoot + "/"),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files.append(File(path: path, source: resolved, size: values.fileSize ?? 0))
        }
        return files
    }
}

// MARK: - Collecting a Book's Files

/// The files of a DAISY book found so far from the references its files
/// make, each checked once (TODO I02).
private struct PackageFileCollector {
    /// The book's folder.
    let root: URL
    /// The folder's path with symbolic links resolved, which every file of
    /// the book must lie inside.
    private let resolvedRoot: String
    /// The files found, by path inside the folder.
    private var found: [String: DAISYPackageInventory.File] = [:]
    /// Paths referred to that name no file.
    private var missing: Set<String> = []
    /// Every path already checked.
    private var checked: Set<String> = []

    /// Starts with nothing found in the folder `root`.
    init(root: URL) {
        self.root = root
        resolvedRoot = root.resolvingSymlinksInPath().path
    }

    /// The files found, in no particular order.
    var files: [DAISYPackageInventory.File] { Array(found.values) }

    /// The paths referred to that name no file, in no particular order.
    var missingPaths: [String] { Array(missing) }

    /// Where the file at `path` is read from, when it is a file found.
    func source(of path: String) -> URL? {
        found[path]?.source
    }

    /// Adds the file `reference`, made in the book's file `file`, names,
    /// and returns its path; nil for a reference to no file of the book
    /// (`DAISYPackageInventory.packagePath(of:in:)`), or to a path no book
    /// file can have (`addPath(_:referredToAs:in:)`).
    /// - Throws: `DAISYPackageError.referenceOutsidePackage` naming the
    ///   reference when it, or a symbolic link it leads to, leaves the
    ///   book's folder.
    @discardableResult
    mutating func add(_ reference: String, in file: String) throws -> String? {
        guard let path = try DAISYPackageInventory.packagePath(of: reference, in: file) else { return nil }
        return try addPath(path, referredToAs: reference, in: file)
    }

    /// Adds the file at `path` inside the book's folder, which `reference`
    /// in the book's file `file` names, and returns `path`; nil when no
    /// book file can have that path (`DAISYPackageInventory.isBookPath(_:)`).
    /// A path that names nothing is noted as missing, and one naming a
    /// folder is kept out of the files.
    /// - Throws: `DAISYPackageError.referenceOutsidePackage` naming
    ///   `reference` when the path is a symbolic link leading out of the
    ///   book's folder.
    @discardableResult
    mutating func addPath(_ path: String, referredToAs reference: String, in file: String) throws -> String? {
        guard DAISYPackageInventory.isBookPath(path) else { return nil }
        guard checked.insert(path).inserted else { return path }

        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            missing.insert(path)
            return path
        }
        // A symbolic link must lead to a file inside the folder, or the
        // copy would hold, or depend on, a file from outside it.
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot + "/") else {
            throw DAISYPackageError.referenceOutsidePackage(reference: reference, file: file)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            found[path] = DAISYPackageInventory.File(path: path, source: resolved, size: values.fileSize ?? 0)
        }
        return path
    }
}
