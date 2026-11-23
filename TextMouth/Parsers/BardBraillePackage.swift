import Foundation
import ZIPFoundation
import CryptoKit

// MARK: - An NLS BARD Braille Book (FMT56)

/// An NLS BARD braille book: a download of the National Library Service's
/// Braille and Audio Reading Download service, a ZIP of BRF volumes and one
/// package file with the extension `.bopf`.
///
/// The package file is an Open eBook 1.0 package, the form of a DAISY 3
/// book's OPF, so it is read by the DAISY reader's own package parser
/// (`DAISYOPFParser`) and its files are reached through the DAISY reader's
/// file providers (`DAISYFileProvider`), which read a ZIP, a folder, and a
/// package file with its folder alike. The package holds:
/// - Dublin Core metadata: title, creator, description, publisher, date,
///   language, subjects, and an identifier;
/// - `<meta name="brl:…" content="…"/>` values: the braille code
///   (`brl:brailleCode`, such as EBAE or UEB), its contraction level
///   (`brl:contractionLevel`, 2 for contracted), the number of volumes and
///   of pages, and the line and page length of the braille;
/// - a manifest of the volumes, each a BRF file, and a spine that puts them
///   in reading order.
///
/// A book of several volumes is one book here: the volumes are read in the
/// spine's order as the pages of one braille file
/// (`BrailleFileReader.read(_:as:code:)`), each volume laid out on its own
/// (`BrailleFilePages.volumeStarts`), and each begins with a heading
/// (`volumeHeading(number:)`).
struct BardBraillePackage {

    // MARK: - Recognizing a package

    /// The extension of a BARD braille package file.
    static let fileExtension = "bopf"

    /// Whether `name` is the name of a BARD braille package file.
    static func isPackageName(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == fileExtension
    }

    /// Whether `url` is a BARD braille book: a package file (`.bopf`), a
    /// folder with a package file at its top level, or a ZIP archive holding
    /// one (`isPackageZip(url:)`). A folder or archive holding another kind
    /// of package file as well, such as a DAISY book's OPF, is not.
    static func isPackage(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let entries = DAISYParser.packageEntryPoints(in: url)
            return !entries.isEmpty && entries.allSatisfy { isPackageName($0.lastPathComponent) }
        }
        if isPackageName(url.lastPathComponent) { return true }
        return url.pathExtension.lowercased() == "zip" && isPackageZip(url: url)
    }

    /// Whether the ZIP archive at `url` holds one BARD braille book: the
    /// archive's files are `holdsPackage(inArchivePaths:)`, and it is no
    /// TextMouth package. The test a DAISY ZIP meets (`DAISYParser.isDAISYZip(url:)`).
    static func isPackageZip(url: URL) -> Bool {
        guard let archive = Archive.openedForReading(at: url) else { return false }
        let paths = ArchiveFileProvider(archive: archive).listFiles()
        return !paths.contains(where: FileImportService.liesInTMBPackage) && holdsPackage(inArchivePaths: paths)
    }

    /// Whether the files of an archive, `paths`, are one BARD braille book:
    /// every package or navigation file in them is a `.bopf` (so a DAISY
    /// book, which has its own, is not one), there is at least one, and they
    /// stand in one folder, or the archive's top level, as a DAISY book's
    /// do. An archive of several books each in a folder of its own is a
    /// batch, whose books import one by one. Several package files at one
    /// level are no one book, and the import refuses the archive saying so
    /// (`open(at:)`).
    static func holdsPackage(inArchivePaths paths: [String]) -> Bool {
        let entries = paths.filter {
            DAISYParser.isPackageEntryName(($0 as NSString).lastPathComponent) && !DAISYParser.isHiddenPackagePath($0)
        }
        guard !entries.isEmpty,
              entries.allSatisfy({ isPackageName(($0 as NSString).lastPathComponent) }) else { return false }
        // Several package files at the same level are still one archive of
        // BARD braille: opening it refuses it by name (`open(at:)`), which
        // tells the cause, where an archive of an unknown format would not.
        let folders = DAISYParser.packageFolders(inArchivePaths: paths)
        return !folders.isEmpty && (folders.count <= 1 || folders.contains(""))
    }

    // MARK: - The headings

    /// The heading each volume of a book of several begins with, in English
    /// whatever the book's language is: "Volume 1", "Volume 2", and so on. It
    /// is part of the book's text, not of the interface, as a braille book's
    /// own running heads are, so it is not translated.
    static func volumeHeading(number: Int) -> String {
        "Volume \(number)" // l10n: no (text of the book, not interface text)
    }

    // MARK: - The package

    /// The package file's path in `provider`.
    let entryPath: String
    /// What the package says: its Dublin Core metadata, its `meta` values,
    /// its manifest, and its spine.
    let package: DAISYOPFResult
    /// The paths of the volumes in `provider`, in the spine's order: the
    /// spine's braille items, or, when it lists none, the manifest's in its
    /// order, as a DAISY book falls back when its spine lists no content
    /// file. A file the spine leaves out is not read, and a volume the
    /// package names that is not there fails the reading, naming it.
    let volumePaths: [String]
    /// Where the package's files are read from.
    let provider: DAISYFileProvider

    /// Opens the BARD braille book at `url`: a package file, its folder, or
    /// a ZIP archive.
    /// - Throws: `DAISYParserError.fileNotFound` for a book that is not
    ///   there, `.notDAISYBook` for one with no package file, `.invalidArchive`
    ///   for a ZIP that cannot be opened, `.malformedXML` naming the package
    ///   file when it is damaged or refused, and `.missingContent` when the
    ///   package names no braille volume.
    static func open(at url: URL) throws -> BardBraillePackage {
        let provider = try DAISYParser.makeFileProvider(from: url)
        let files = provider.listFiles()
        // The package file: the one chosen, when `url` is a package file
        // (listed first, `EntryFirstFileProvider`); otherwise the one
        // package file of the folder or archive, or the shallowest, and
        // several at that depth name no one book. Hidden files and the
        // folder macOS adds to an archive hold no book.
        let candidates = files.filter { isPackageName($0) && !DAISYParser.isHiddenPackagePath($0) }
        guard let first = candidates.first else { throw DAISYParserError.notDAISYBook }
        let entryPath: String
        if isPackageName(url.lastPathComponent) {
            entryPath = first
        } else {
            let depth = { (path: String) in path.split(separator: "/").count }
            let shallowest = candidates.filter { depth($0) == candidates.map(depth).min() }
            guard shallowest.count == 1 else {
                throw DAISYParserError.malformedXML(
                    file: shallowest[0], reason: "it is one of \(shallowest.count) package files at the same level, so no one book is meant" // l10n: no (a parser's damage reason)
                )
            }
            entryPath = shallowest[0]
        }

        let package = try DAISYOPFParser(path: entryPath, in: provider).parse()

        /// Whether a manifest item is a braille volume: a BRF or BRL file by
        /// its media type or its name, never the package file itself.
        func isVolume(_ item: DAISYManifestItem) -> Bool {
            let type = item.mediaType.lowercased()
            let name = (item.href as NSString).pathExtension.lowercased()
            return (type.contains("brf") || type.contains("brl") || name == "brf" || name == "brl")
                && !isPackageName(item.href)
        }
        let spineItems = package.spineItemRefs.compactMap { package.manifest[$0] }.filter(isVolume)
        let items = spineItems.isEmpty
            ? package.manifestOrder.compactMap { package.manifest[$0] }.filter(isVolume)
            : spineItems

        // Each volume's path in the package, found in the files as the
        // package spells it or, failing that, in any letter case (a package
        // made on another system), and listed once.
        var paths: [String] = []
        for item in items {
            let named = ParserUtilities.resolvedPackagePath(item.href, relativeTo: entryPath, preserveFragment: false)
            let found = files.first { $0 == named }
                ?? files.first { $0.caseInsensitiveCompare(named) == .orderedSame }
                ?? named
            if !paths.contains(found) { paths.append(found) }
        }
        guard !paths.isEmpty else {
            throw DAISYParserError.malformedXML(file: entryPath, reason: "it lists no braille volume") // l10n: no (a parser's damage reason)
        }
        return BardBraillePackage(entryPath: entryPath, package: package, volumePaths: paths, provider: provider)
    }

    // MARK: - Metadata

    /// The title the package gives, or empty.
    var title: String { package.title }

    /// The author the package names, as a DAISY book's and an EPUB's are
    /// read: the first creator, trimmed, and none for the placeholder
    /// "Unknown" (`Book.isUnknownAuthor(_:)`).
    var author: String {
        let name = package.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return Book.isUnknownAuthor(name) ? "" : name
    }

    /// The package's metadata for the library: the title and author, and the
    /// fields the library keeps for a book beyond them (publisher, date,
    /// language, identifier), in the form an EPUB's are kept. A package
    /// holding no description or subjects field for the library leaves them
    /// in `package`.
    var metadata: (title: String, author: String, epub: EPUBMetadata) {
        // The language "und" is how a book says it names none.
        let language = package.language.lowercased() == "und" ? "" : package.language
        return (title, author, EPUBMetadata(
            title: title, author: author, publisher: package.publisher, publicationDate: package.date,
            isbn: "", language: language, identifier: package.identifier, epubVersion: ""
        ))
    }

    /// The title and author of the BARD braille book at `url`, read from its
    /// package; nil when `url` is no package or its package cannot be read.
    static func readMetadata(from url: URL) -> (title: String, author: String, epub: EPUBMetadata)? {
        try? open(at: url).metadata
    }

    // MARK: - The braille

    /// The braille code the package names (`brl:brailleCode`), in capitals,
    /// such as "EBAE" or "UEB"; nil when it names none.
    var brailleCode: String? {
        package.metas["brl:braillecode"].map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The contraction level the package names (`brl:contractionLevel`): 2
    /// for contracted braille, 1 for uncontracted; nil when it names none.
    var contractionLevel: Int? {
        package.metas["brl:contractionlevel"].flatMap { Int($0) }
    }

    /// The whole number the package gives `name` (a `brl:` meta name in
    /// lowercase), or nil when it gives none or one that is not.
    private func number(named name: String) -> Int? {
        package.metas[name].flatMap { Int($0) }
    }

    /// The number of volumes the package declares (`brl:volumes`).
    var declaredVolumeCount: Int? { number(named: "brl:volumes") }
    /// The number of braille pages the package declares (`brl:pages`).
    var declaredPageCount: Int? { number(named: "brl:pages") }
    /// The width of a braille line in cells (`brl:lineLength`), when the
    /// package gives one the analyzer can use as the line width (a PEF's
    /// declared width is held to the same range, 18 to 80).
    var lineLength: Int? { number(named: "brl:linelength").flatMap { (18...80).contains($0) ? $0 : nil } }
    /// The number of lines on a braille page (`brl:pageLength`). The
    /// analyzer reads each page's rows as the file gives them, so it takes
    /// no page length; this is kept for the record.
    var pageLength: Int? { number(named: "brl:pagelength") }

    /// The stored value of the bundled table the package says its braille
    /// reads with, by its code and contraction level:
    /// - EBAE at level 2: the contracted EBAE table TextMouth reads EBAE with
    ///   (`BrailleTableGuess.ebaeTableID`); at level 1, English Braille,
    ///   American Edition, uncontracted;
    /// - UEB at level 2: Unified English Braille, contracted; at level 1,
    ///   uncontracted.
    /// Nil for any other code, or a level other than 1 and 2, which a plain
    /// BRF's import then reads as the Braille setting says.
    static func tableID(brailleCode: String?, contractionLevel: Int?) -> String? {
        switch (brailleCode, contractionLevel) {
        case ("EBAE", 2): return BrailleTableGuess.ebaeTableID
        case ("EBAE", 1): return "en-us-g1.ctb"
        case ("UEB", 2): return "en-ueb-g2.ctb"
        case ("UEB", 1): return "en-ueb-g1.ctb"
        default: return nil
        }
    }

    /// The table the package names, when TextMouth has it (`tableID(brailleCode:contractionLevel:)`
    /// and the table catalog), else nil.
    var table: String? {
        Self.tableID(brailleCode: brailleCode, contractionLevel: contractionLevel)
            .flatMap { BrailleTableCatalog.table(withID: $0) != nil ? $0 : nil }
    }

    /// The table the BARD braille book at `url` should be imported with, by
    /// what its package says (`table`); nil for a book that is no package,
    /// whose package cannot be read, or whose package names no table
    /// TextMouth has. The import then reads the book as it reads a plain BRF
    /// (the Braille setting's table, or the guess from the braille itself:
    /// `BrailleTableGuess`), and Book Information shows the table it used.
    static func importTable(forFileAt url: URL) -> String? {
        // A plain BRF or PEF is no package, and is never tried as an archive.
        guard isPackage(at: url) else { return nil }
        return (try? open(at: url))?.table
    }

    // MARK: - The Checksum

    /// The checksum the book is known by, made as the checksum of the same
    /// book kept as loose files is (`DAISYPackageInventory.contentHash()`):
    /// the digest of the package file and the paths and sizes of it and of
    /// every file its manifest lists that the package holds, paths counted
    /// from the package file's folder. A ZIP of a BARD book and its folder
    /// have the same one, so the second is found a duplicate of the first.
    func contentHash() throws -> String {
        let folder = entryPath.split(separator: "/").dropLast().joined(separator: "/")
        let entryName = (entryPath as NSString).lastPathComponent
        let held = Set(provider.listFiles())
        var sizes: [String: Int64] = [entryName: provider.byteCount(of: entryPath) ?? 0]
        for href in package.manifest.values.map(\.href) {
            // A reference that climbs out of the folder is no file of the book.
            guard let path = try? DAISYPackageInventory.packagePath(of: href, in: entryName),
                  DAISYPackageInventory.isBookPath(path) else { continue }
            let inArchive = folder.isEmpty ? path : folder + "/" + path
            if held.contains(inArchive) { sizes[path] = provider.byteCount(of: inArchive) ?? 0 }
        }
        let digest = Insecure.MD5.hash(data: try provider.readFile(at: entryPath)).map { String(format: "%02hhx", $0) }.joined()
        return DAISYPackageInventory.contentHash(entryDigest: digest, files: sizes.map { (path: $0.key, size: $0.value) })
    }

    /// The checksum of the BARD braille book in the ZIP archive at `url`
    /// (`contentHash()`); nil for any other file, and for an archive whose
    /// package cannot be read.
    static func contentHash(ofZipAt url: URL) -> String? {
        guard url.pathExtension.lowercased() == "zip", isPackageZip(url: url) else { return nil }
        return try? open(at: url).contentHash()
    }

    // MARK: - Reading the volumes

    /// The sentence a refusal of the package or of one of its files is made
    /// of: the damaged-file sentence of a book (`PackageDamage`), naming
    /// `file`, with `reason`, in English, after it.
    private static func damaged(_ file: String, _ reason: String) -> DAISYParserError {
        DAISYParserError.malformedXML(file: file, reason: reason)
    }

    /// `error`'s sentence as the reason a file is damaged, which begins with a
    /// lowercase letter and has no full stop, as the other reasons do.
    private static func reason(of error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first else { return "it is not braille" } // l10n: no (a parser's damage reason)
        return first.lowercased() + text.dropFirst()
    }

    /// Refuses the book when its volumes together are larger than one braille
    /// file may be (`BrailleBookReader.maximumFileBytes`), by the sizes the
    /// file system or the archive records, before any volume is read, as a
    /// single BRF is refused by its size. A volume whose size is not known
    /// is counted when it has been read.
    /// - Throws: `BrailleFileError.fileTooLarge`.
    private func requireVolumesWithinLimit() throws {
        let known = volumePaths.compactMap { provider.byteCount(of: $0) }.reduce(0, +)
        guard known <= BrailleBookReader.maximumFileBytes else { throw BrailleFileError.fileTooLarge }
    }

    /// The pages of every volume, read as BRF files whose cells are written
    /// in `code`, as one set of pages whose volumes are marked
    /// (`BrailleFilePages.volumeStarts`) and numbered by their place in the
    /// spine. The package's line length is not used: the analyzer measures
    /// the width the volumes are laid out in, which a package may not state.
    ///
    /// The package's declared page count is only checked: a difference is
    /// logged, never a reason to refuse the book.
    /// - Throws: the damaged-file sentence (`DAISYParserError.malformedXML`)
    ///   naming a volume that is not in the package, that is empty, or that
    ///   is not braille in `code`, with the reason after it;
    ///   `BrailleFileError.fileTooLarge` when the volumes together are larger
    ///   than one braille file may be (`BrailleBookReader.maximumFileBytes`),
    ///   checked from their sizes before any is read; and the errors of the
    ///   limits of a braille file (`BrailleFileReader.pages(fromText:kind:code:)`).
    func readPages(code: BrailleFileCode) throws -> BrailleFilePages {
        let files = Set(provider.listFiles())
        // A volume the package lists that is not there is named before any is read.
        for path in volumePaths where !files.contains(path) {
            throw Self.damaged(path, "the book's package lists it, but it is not there") // l10n: no (a parser's damage reason)
        }
        try requireVolumesWithinLimit()

        var book = BrailleFilePages(kind: .brf)
        var bytes: Int64 = 0
        var emptyLastPages = 0
        for (index, path) in volumePaths.enumerated() {
            let data = try provider.readFile(at: path)
            bytes += Int64(data.count)
            guard bytes <= BrailleBookReader.maximumFileBytes else { throw BrailleFileError.fileTooLarge }
            let volume: BrailleFilePages
            do {
                volume = try BrailleFileReader.pages(fromText: data, kind: .brf, code: code)
            } catch let error as BrailleFileError {
                throw Self.damaged(path, Self.reason(of: error))
            }
            // An empty volume is refused, as DAISY refuses an empty content file.
            guard volume.pageCount > 0 else {
                throw Self.damaged(path, "it holds no braille") // l10n: no (a parser's damage reason)
            }
            if volume.endsWithAnEmptyPage { emptyLastPages += 1 }
            try book.append(volume: volume, number: index + 1)
        }
        // The package's line length is only checked.
        if let declared = lineLength {
            let measured = BraillePageAnalyzer.commonWidth(ofVolumesIn: book)
            if measured != declared {
                DiagnosticLog.event(.import, "BARD_BRAILLE_WIDTH: the package declares \(declared) cells a line; the volumes measure \(measured)")
            }
        }
        // So is its page count, which leaves out each volume's empty last page.
        let counted = book.pageCount - emptyLastPages
        if let declared = declaredPageCount, declared != counted {
            DiagnosticLog.event(
                .import,
                "BARD_BRAILLE_PAGES: the package declares \(declared) page(s); its \(book.volumeStarts.count) "
                    + "volume(s) hold \(counted)"
            )
        }
        return book
    }
}

