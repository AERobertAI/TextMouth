import Foundation
import ZIPFoundation

// MARK: - A Comic Book Archive

/// A comic book archive's pages (FMT34): the pictures of a ZIP archive named
/// .cbz, in the natural order of their paths ("page2" before "page10", a
/// folder's pictures together), as comic readers order them, with what its
/// optional ComicInfo.xml says of the book and its pages
/// (`PageImageComicInfo`).
///
/// Nothing is extracted to disk: each page's file is read into memory when
/// its turn comes, within the limit for one file of an archive
/// (`ArchiveEntryReader`), checked against the archive's checksum, and
/// decoded within `PageImageDecoding`'s limits. Hidden files and the
/// `__MACOSX` folder macOS adds to archives hold no pages.
///
/// Vision reads a page's text top to bottom and left to right; it knows
/// nothing of a comic's panels or speech balloons, so the words of a page of
/// panels are read in the order they stand on the page, not in the order of
/// the story.
struct PageImageArchive: PageImageBook {
    /// The extensions of the files taken as pages, in lowercase: the kinds of
    /// picture comic book archives hold that ImageIO decodes within
    /// `PageImageDecoding.readableTypes`. The bytes decide the kind in the
    /// end: a page whose bytes are another kind is refused by it.
    static let pageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff"]

    /// The name of the file that describes the book and its pages, in any
    /// capitals.
    static let comicInfoName = "comicinfo.xml"

    /// The most bytes ComicInfo.xml may hold: a real one is a few kilobytes,
    /// a long summary included.
    static let maximumComicInfoBytes: Int64 = 1_000_000

    /// The tag of the debug log's line for a page's file that ZIPFoundation
    /// could not read (`ArchiveEntryReader.unreadableReason`), as each
    /// archive format has its own.
    static let unreadableEntryLogTag = "COMIC_ZIP_ERROR"

    /// One page: its file in the archive and the title of its chapter.
    struct Page {
        /// The page's file.
        let entry: Entry
        /// The page's chapter title.
        let title: String
    }

    /// The archive, open for reading.
    private let archive: Archive
    /// The pages, in order: every picture but those ComicInfo.xml calls
    /// deleted.
    let pages: [Page]
    /// What ComicInfo.xml says of the book, when it is there and readable.
    let comicInfo: PageImageComicInfo?

    var subject: PageImageWording.Subject { .archive }
    var pageCount: Int { pages.count }

    /// The pages of the comic book archive at `url`.
    /// - Parameter maximumPages: the most pictures it may hold (tests give a
    ///   smaller limit than the book's).
    /// - Throws: `PageImageError.notAnArchive` when it is no ZIP archive,
    ///   `.tooManyPictures` when it holds more pictures than TextMouth reads
    ///   in one book, `.noPictures` when it holds none, and
    ///   `EncryptedArchiveError` when an entry is protected by a password.
    init(url: URL, maximumPages: Int = PageImageWording.maximumPages) throws {
        // A password-protected archive is refused in words that say so (B27).
        try UnlockedSources.refuseIfLocked(at: url)
        guard let archive = Archive.openedForReading(at: url) else { throw PageImageError.notAnArchive }
        let contents = try Self.contents(of: archive, maximumPages: maximumPages)
        let comicInfo = contents.comicInfo.flatMap { Self.comicInfo(in: $0, of: archive) }
        let pages = contents.pictures.enumerated().compactMap { index, entry -> (entry: Entry, listing: PageImageComicInfo.Page?)? in
            let listing = comicInfo?.pages[index]
            return listing?.isDeleted == true ? nil : (entry, listing)
        }
        guard !pages.isEmpty else { throw PageImageError.noPictures }
        self.archive = archive
        self.comicInfo = comicInfo
        self.pages = pages.enumerated().map { number, page in
            Page(entry: page.entry, title: page.listing?.title ?? PageImageWording.pageTitle(number + 1))
        }
    }

    func title(ofPage index: Int) -> String {
        pages[index].title
    }

    /// The picture of page `index`, read from the archive and decoded: the
    /// file's main picture, so a TIFF of several pages among the pictures is
    /// one page of the book.
    /// - Throws: `PageImageError.damagedPage` for a file that cannot be read
    ///   from the archive, holds more than one file may, or does not match
    ///   its checksum, and what decoding throws for a picture.
    func decodedPage(at index: Int) throws -> DecodedPage {
        let entry = pages[index].entry
        let data: Data
        do {
            let read = try ArchiveEntryReader.read(entry, in: archive)
            // ZIPFoundation reports 0 for a checksum it could not read, which
            // can judge nothing, as the EPUB reader allows.
            guard entry.checksum == 0 || read.checksum == entry.checksum else {
                throw PageImageError.damagedPage(file: entry.path, reason: PageImageWording.failsChecksum)
            }
            data = read.data
        } catch let error as PageImageError {
            throw error
        } catch let overflow as ArchiveEntryOverflow {
            throw PageImageError.damagedPage(file: entry.path, reason: overflow.reason)
        } catch {
            let reason = ArchiveEntryReader.unreadableReason(of: entry, error: error, tag: Self.unreadableEntryLogTag)
            throw PageImageError.damagedPage(file: entry.path, reason: reason)
        }
        let source = try PageImageSource(data: data)
        // A source always has a page; the guard keeps that from being assumed.
        guard let main = source.pageIndexes.first else { throw PageImageError.notAPicture }
        return try source.decodedPage(at: main)
    }

    // MARK: - What the Archive Holds

    /// The archive's pictures in natural order, and its ComicInfo.xml: the
    /// one nearest the archive's top, first in natural order among those as
    /// near. Folders, hidden files, and what lies in `__MACOSX` are passed
    /// over. A hostile archive can list millions of entries, so the pictures
    /// are counted against `maximumPages` as they are listed, before any is
    /// sorted, and only the best description so far is kept.
    /// - Throws: `PageImageError.tooManyPictures` at the first picture past
    ///   `maximumPages`.
    private static func contents(of archive: Archive, maximumPages: Int) throws -> (pictures: [Entry], comicInfo: Entry?) {
        let inNaturalOrder: (Entry, Entry) -> Bool = {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let depth = { (entry: Entry) in entry.path.split(separator: "/").count }
        var pictures: [Entry] = []
        var description: Entry?
        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/")
            guard let name = parts.last, !parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else {
                continue
            }
            if name.lowercased() == comicInfoName {
                // Nearer the top wins, then the first in natural order.
                if let best = description, depth(best) < depth(entry)
                    || (depth(best) == depth(entry) && !inNaturalOrder(entry, best)) { continue }
                description = entry
            } else if pageExtensions.contains((String(name) as NSString).pathExtension.lowercased()) {
                guard pictures.count < maximumPages else { throw PageImageError.tooManyPictures }
                pictures.append(entry)
            }
        }
        pictures.sortStably(by: inNaturalOrder)
        return (pictures, description)
    }

    /// What `entry`, a ComicInfo.xml, says, or nil when it is too large or
    /// cannot be read: it is only a description, so a book never fails for
    /// it.
    private static func comicInfo(in entry: Entry, of archive: Archive) -> PageImageComicInfo? {
        guard let read = try? ArchiveEntryReader.read(entry, in: archive, limit: maximumComicInfoBytes),
              entry.checksum == 0 || read.checksum == entry.checksum else { return nil }
        return PageImageComicInfo(data: read.data)
    }

    // MARK: - The Book's Names

    /// The title and author the comic book archive at `url` names in its
    /// ComicInfo.xml (`PageImageComicInfo.bookTitle`, `.writer`), each nil
    /// when it names none; nil when the archive cannot be read. Reading a
    /// book's names never fails an import, so the import's own reading of
    /// the pages says what is wrong.
    static func metadata(ofArchiveAt url: URL) -> (title: String?, author: String?)? {
        guard let archive = try? PageImageArchive(url: url), let info = archive.comicInfo else { return nil }
        return (info.bookTitle, info.writer)
    }
}

// MARK: - ComicInfo.xml

/// What a comic book archive's ComicInfo.xml says of the book and its pages,
/// in the schema comic readers share (ComicRack's): the book's title, series,
/// number, and writer, and for each picture, by its place among the
/// archive's pictures in natural order (`Image`, from 0), its type and its
/// bookmark. Only these are read.
struct PageImageComicInfo: Equatable {
    /// What the file says of one picture.
    struct Page: Equatable {
        /// The picture's Type as the file writes it: a list of the schema's
        /// values ("FrontCover", "Story", "Deleted", and the others) apart by
        /// white space, as in "Advertisement Deleted" (ComicInfo 2.0 and the
        /// 2.1 draft).
        var type: String?
        /// The name the file gives the picture, such as a chapter's.
        var bookmark: String?

        /// The value a picture's Type has when the file gives none.
        static let defaultType = "Story" // l10n: no (a ComicInfo.xml name, not interface text)

        /// The values of the picture's Type, in the order written; the
        /// schema's default, "Story", when it lists none.
        var types: [String] {
            let listed = (type ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            return listed.isEmpty ? [Self.defaultType] : listed
        }

        /// Whether the picture is no page of the book, as comic readers leave
        /// out a picture whose types include "Deleted".
        var isDeleted: Bool { types.contains("Deleted") }

        /// The title of the picture's chapter: its bookmark, made fit for a
        /// chapter line (`chapterTitle(_:)`), else the name of the first cover
        /// among its types (`PageImageWording.coverTitle(forPageTypes:)`); nil
        /// for a page that keeps its number.
        var title: String? {
            bookmark.flatMap(PageImageComicInfo.chapterTitle) ?? PageImageWording.coverTitle(forPageTypes: types)
        }
    }

    /// The book's title.
    var title: String?
    /// The series the book belongs to.
    var series: String?
    /// The book's number in its series.
    var number: String?
    /// The book's writer or writers, as the file lists them.
    var writer: String?
    /// What the file says of each picture, by its place among the pictures.
    var pages: [Int: Page] = [:]

    /// The title the book is listed under: its title, else its series with
    /// its number ("Harbour Notices 1"); nil when the file names neither.
    var bookTitle: String? {
        if let title { return title }
        guard let series else { return nil }
        return number.map { "\(series) \($0)" } ?? series
    }

    /// The most characters kept of a name the file gives.
    static let maximumNameLength = 200

    /// What ComicInfo.xml's bytes `data` say; nil when they cannot be read
    /// safely or are not well formed, which the guard and the parser decide
    /// as for every XML part of a book (`PackageSAXParser`).
    init?(data: Data) {
        let parser = ComicInfoParser(data: data)
        guard (try? parser.parseDocument()) != nil else { return nil }
        self = parser.info
    }

    /// An empty description, for the parser to fill in.
    fileprivate init() {}

    /// `name` made fit to be a chapter's title on its marker line: every run
    /// of white space and line breaks one space, the angle brackets and runs
    /// of hyphens that could end or open a comment taken out, cut to
    /// `maximumNameLength`; nil when nothing is left.
    static func chapterTitle(_ name: String) -> String? {
        var title = cleaned(name) ?? ""
        title.removeAll { $0 == "<" || $0 == ">" }
        while title.contains("--") {
            title = title.replacingOccurrences(of: "--", with: "-")
        }
        return cleaned(title)
    }

    /// `text` with every run of white space and line breaks made one space,
    /// trimmed, and cut to `maximumNameLength`; nil when nothing is left.
    static func cleaned(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = String(words.joined(separator: " ").prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

/// Why a ComicInfo.xml could not be read: never shown, since a book is read
/// without its description when it cannot be.
private struct ComicInfoUnreadable: Error {}

/// Reads ComicInfo.xml's few elements through the guarded driver every XML
/// part of a book is read with (`PackageSAXParser`): no entity of its own,
/// no external entity, and no tag of too many attributes reaches the parser.
private final class ComicInfoParser: PackageSAXParser {
    /// What has been read.
    var info = PageImageComicInfo()
    /// The local names of the open elements, the root first.
    private var path: [String] = []
    /// The text of the element being read, when it is one of the book's
    /// names.
    private var text = ""

    /// The elements under the root whose text is read.
    private static let names: Set<String> = ["Title", "Series", "Number", "Writer"] // l10n: no (a ComicInfo.xml name, not interface text)

    init(data: Data) {
        super.init(
            data: data, file: "ComicInfo.xml",
            malformedXMLError: { _, _ in ComicInfoUnreadable() },
            refusedXMLError: { _, _ in ComicInfoUnreadable() }
        )
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes attributeDict: [String: String]
    ) {
        path.append(ParserUtilities.stripNamespacePrefix(elementName))
        text = ""
        // A picture's entry: <ComicInfo><Pages><Page Image="0" Type="…" Bookmark="…"/>.
        guard path == ["ComicInfo", "Pages", "Page"], // l10n: no (a ComicInfo.xml name, not interface text)
              let image = attributeDict["Image"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), // l10n: no (a ComicInfo.xml name, not interface text)
              image >= 0, info.pages[image] == nil else { return }
        info.pages[image] = PageImageComicInfo.Page(
            type: attributeDict["Type"].flatMap(PageImageComicInfo.cleaned),
            bookmark: attributeDict["Bookmark"] // l10n: no (a ComicInfo.xml name, not interface text)
        )
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        keep(string)
    }

    /// A name written in a CDATA section is a name all the same.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        keep(String(decoding: CDATABlock, as: UTF8.self))
    }

    /// Adds `string` to the text being read when it is part of one of the
    /// book's names, and only as much as a name may hold.
    private func keep(_ string: String) {
        guard path.count == 2, Self.names.contains(path[1]),
              text.count < PageImageComicInfo.maximumNameLength * 2 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if path.count == 2, path[0] == "ComicInfo" {
            let value = PageImageComicInfo.cleaned(text)
            switch path[1] {
            case "Title": info.title = info.title ?? value // l10n: no (a ComicInfo.xml name, not interface text)
            case "Series": info.series = info.series ?? value // l10n: no (a ComicInfo.xml name, not interface text)
            case "Number": info.number = info.number ?? value // l10n: no (a ComicInfo.xml name, not interface text)
            case "Writer": info.writer = info.writer ?? value // l10n: no (a ComicInfo.xml name, not interface text)
            default: break
            }
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }
}
