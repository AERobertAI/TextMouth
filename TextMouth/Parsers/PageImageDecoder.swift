import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

/// Why a picture of a page, or a book of them, could not be read (FMT34).
/// Each case has the sentence an import says when it ends the whole book
/// (`errorDescription`), and, for what can go wrong on one page of several,
/// the reason that page's report gives (`pageReason`); the words are
/// `PageImageWording`'s.
enum PageImageError: LocalizedError, Equatable, Sendable {
    /// ImageIO finds no picture in the bytes.
    case notAPicture
    /// ImageIO knows the picture's kind, which TextMouth does not decode,
    /// named by the system's description of it.
    case unreadableKind(String)
    /// The picture says it holds more pixels than TextMouth decodes.
    case tooLarge(width: Int, height: Int)
    /// ImageIO knows the picture but could not decode it.
    case cannotDecode
    /// The page's file `file` in a comic book archive could not be taken out
    /// of it, for `reason`, which completes "The file “…” in this comic book
    /// archive is damaged or incomplete: …" (`PackageDamage`): an archive
    /// entry's own reason (`ArchiveEntryReader`), or a checksum that does not
    /// match.
    case damagedPage(file: String, reason: String)
    /// A book of more pages than TextMouth reads in one book.
    case tooManyPages(Int, PageImageWording.Subject)
    /// A comic book archive that is no ZIP archive.
    case notAnArchive
    /// A comic book archive that holds no picture TextMouth reads.
    case noPictures
    /// Text recognition found no text on any of `pageCount` pages.
    case noText(PageImageWording.Subject, pageCount: Int)
    /// Text recognition could not run at all, for `reason`.
    case recognitionUnavailable(PageImageWording.Subject, reason: String)
    /// Every page that held anything failed, as the report's sentence says
    /// (`PDFExtractionDiagnostics.problem`): nothing could be read.
    case noPageReadable(String)

    var errorDescription: String? {
        switch self {
        case .notAPicture: return PageImageWording.notAPicture
        case .unreadableKind(let kind): return PageImageWording.unreadableKind(kind)
        case let .tooLarge(width, height): return PageImageWording.tooLarge(width: width, height: height)
        case .cannotDecode: return PageImageWording.cannotDecode
        case let .damagedPage(file, reason):
            return PackageDamage.message(
                file: file, reason: reason, container: PageImageWording.Subject.archive.phrase,
                original: PageImageWording.archiveToGetAgain
            )
        case let .tooManyPages(count, subject): return PageImageWording.tooManyPages(count, in: subject)
        case .notAnArchive: return PageImageWording.notAnArchive
        case .noPictures: return PageImageWording.noPictures
        case let .noText(subject, pageCount): return PageImageWording.noText(in: subject, pageCount: pageCount)
        case let .recognitionUnavailable(subject, reason):
            return PageImageWording.recognitionUnavailable(in: subject, reason: reason)
        case .noPageReadable(let sentence): return sentence
        }
    }

    /// Why one page of a longer book could not be read, completing the
    /// parenthesis of a page its report names: "page 3 (its picture could
    /// not be decoded)". Every case a single page can meet has its own; the
    /// others, which end a whole book, give their sentence.
    var pageReason: String {
        switch self {
        case .notAPicture: return PageImageWording.pageNotAPicture
        case .unreadableKind(let kind): return PageImageWording.pageOfUnreadableKind(kind)
        case let .tooLarge(width, height): return PageImageWording.pageTooLarge(width: width, height: height)
        case .cannotDecode: return PageImageWording.pageCannotDecode
        case .damagedPage(_, let reason): return PageImageWording.pageFileDamaged(reason)
        case .tooManyPages, .notAnArchive, .noPictures, .noText, .recognitionUnavailable, .noPageReadable:
            return errorDescription ?? ""
        }
    }
}

// MARK: - The Limits of a Decode

/// How TextMouth decodes an untrusted picture for text recognition (FMT34),
/// in its own process, within limits that every decode passes:
///
/// - **Only common kinds.** ImageIO picks its decoder by the bytes, never by
///   the name, so the kind it identifies is checked against `readableTypes`
///   before a pixel is decoded: PNG, JPEG, HEIC and HEIF, TIFF, GIF, and
///   WebP, the common kinds that photographs, scans, and the web use.
///   Camera raw, DNG, Photoshop, OpenEXR, and the rest of ImageIO's rarer
///   decoders are never reached from a book.
/// - **A declared size checked first.** A picture says its size in its
///   header, which ImageIO reads without decoding; one past
///   `PageImageWording.maximumMegapixels` is refused, so a small file that
///   claims a vast picture cannot fill the Mac's memory.
/// - **Decoded small.** Each page is decoded through ImageIO's thumbnail
///   reader, which applies the picture's EXIF orientation (which
///   `VNImageRequestHandler(cgImage:)` ignores) and decodes no more than
///   `decodedPixels`, downsampling as it reads where the format allows (a
///   JPEG is scaled while it is decoded), never from the small preview a
///   camera embeds.
/// - **Flattened.** The page is drawn onto an opaque background before it is
///   read, since Vision finds no text drawn on transparency.
enum PageImageDecoding {
    /// The kinds of picture TextMouth decodes, by the type identifier ImageIO
    /// gives the bytes.
    static let readableTypes: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier,
        UTType.tiff.identifier, UTType.gif.identifier, UTType.webP.identifier,
    ]

    /// The most pixels a picture may declare, from `PageImageWording`.
    static let maximumPixels = PageImageWording.maximumMegapixels * 1_000_000

    /// The most pixels a page is decoded at: 16 megapixels, a 12 megapixel
    /// phone photograph at its full size, and 64 MB to hold once flattened.
    /// A larger picture is scaled down to it,
    /// its proportions kept, so a tall strip of a page is not shrunk to a
    /// sliver as a cap on its longest side would shrink it.
    static let decodedPixels = 16_000_000

    /// Refuses a picture that declares `width` by `height` pixels when it
    /// declares no size, or more than `maximumPixels`, counted in floating
    /// point so that no declared size can overflow.
    /// - Throws: `PageImageError.cannotDecode` for a size of nothing, and
    ///   `.tooLarge` for one past the limit.
    static func checkDeclaredSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw PageImageError.cannotDecode }
        guard Double(width) * Double(height) <= Double(maximumPixels) else {
            throw PageImageError.tooLarge(width: width, height: height)
        }
    }

    /// The longest side to decode a picture of `width` by `height` pixels at,
    /// as the thumbnail reader takes its limit: the picture's own longest
    /// side when it holds no more than `decodedPixels`, else the side that
    /// scales its area down to that, rounded up.
    static func decodedLongestSide(width: Int, height: Int) -> Int {
        let longest = max(width, height)
        let pixels = Double(width) * Double(height)
        guard pixels > Double(decodedPixels) else { return longest }
        let scale = (Double(decodedPixels) / pixels).squareRoot()
        return max(1, Int((Double(longest) * scale).rounded(.up)))
    }
}

// MARK: - A Picture's Pages

/// A picture file's pages, ready to be decoded one at a time for text
/// recognition within `PageImageDecoding`'s limits: every page of a TIFF,
/// the main picture of any other kind (an animated GIF's or PNG's other
/// frames, and a HEIC's other pictures, are no pages).
struct PageImageSource {
    /// The type ImageIO identified the bytes as (`PageImageDecoding.readableTypes`).
    let typeIdentifier: String
    /// The indexes, among the source's pictures, of the book's pages, in order.
    let pageIndexes: [Int]
    /// ImageIO's reader of the bytes.
    private let source: CGImageSource

    /// What ImageIO is told as it opens bytes: decode nothing until asked,
    /// and keep nothing decoded. Made afresh each time, since a Core
    /// Foundation dictionary is not safe to share between threads.
    private static var openingOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    /// The pages of the picture file at `url`, read lazily from the file:
    /// every page of a TIFF.
    /// - Parameter maximumPages: the most pages a TIFF may have (tests give
    ///   a smaller limit than the book's).
    /// - Throws: `PageImageError` when the bytes are no picture, a kind
    ///   TextMouth does not decode, or a TIFF of more pages than it reads in
    ///   one book.
    init(url: URL, maximumPages: Int = PageImageWording.maximumPages) throws {
        try self.init(
            source: CGImageSourceCreateWithURL(url as CFURL, Self.openingOptions),
            readingEveryPage: true, maximumPages: maximumPages
        )
    }

    /// The one page of a picture held in `data`, as a comic book archive's
    /// picture is: its main picture, even of a TIFF of several.
    /// - Throws: `PageImageError` when the bytes are no picture or a kind
    ///   TextMouth does not decode.
    init(data: Data) throws {
        try self.init(
            source: CGImageSourceCreateWithData(data as CFData, Self.openingOptions),
            readingEveryPage: false, maximumPages: 1
        )
    }

    /// Checks the kind of `source` and lists its pages, decoding nothing:
    /// with `readingEveryPage`, every picture of a TIFF, up to
    /// `maximumPages`; otherwise, and for every other kind, the main picture
    /// alone.
    private init(source: CGImageSource?, readingEveryPage: Bool, maximumPages: Int) throws {
        guard let source, let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0 else {
            throw PageImageError.notAPicture
        }
        guard PageImageDecoding.readableTypes.contains(type) else {
            throw PageImageError.unreadableKind(UTType(type)?.localizedDescription ?? PageImageWording.unnamedKind)
        }
        let count = CGImageSourceGetCount(source)
        if readingEveryPage, type == UTType.tiff.identifier {
            // A TIFF's pictures are its pages, each read in turn.
            guard count <= maximumPages else { throw PageImageError.tooManyPages(count, .picture) }
            pageIndexes = Array(0..<count)
        } else {
            pageIndexes = [CGImageSourceGetPrimaryImageIndex(source)]
        }
        self.source = source
        typeIdentifier = type
    }

    /// The picture of the page at `index` (one of `pageIndexes`), upright and
    /// no larger than `PageImageDecoding.decodedPixels`, as decoded: it may
    /// still have an alpha channel (`DecodedPage.flattened(onto:)`).
    /// - Throws: `PageImageError.tooLarge` for a page that declares more than
    ///   `PageImageDecoding.maximumPixels`, before anything is decoded, and
    ///   `.cannotDecode` for one ImageIO cannot decode or that declares no
    ///   size.
    func decodedPage(at index: Int) throws -> DecodedPage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        try PageImageDecoding.checkDeclaredSize(width: width, height: height)
        let options: [CFString: Any] = [
            // Always from the picture itself, never from the small preview a
            // camera embeds in it.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // The EXIF orientation applied, so the page is upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PageImageDecoding.decodedLongestSide(width: width, height: height),
            // Decoded now, inside the caller's autorelease pool, not later.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw PageImageError.cannotDecode
        }
        return DecodedPage(image: image)
    }
}

// MARK: - A Decoded Page

/// One page's picture, decoded and upright, before it is flattened.
struct DecodedPage {
    /// The picture as decoded, possibly with an alpha channel.
    let image: CGImage

    /// Whether the picture has an alpha channel, so that what it draws on
    /// transparency could be lost against one background and seen against
    /// another.
    var hasAlpha: Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// The background a page is flattened onto.
    enum Background: Sendable {
        /// White: dark print on transparency, the usual case, shows on it.
        case white
        /// Black: light print on transparency, which white would hide.
        case black

        /// The background's gray level.
        var gray: CGFloat { self == .white ? 1 : 0 }
    }

    /// The page drawn onto an opaque `background` in 8-bit sRGB, the same
    /// size, so that text drawn on transparency is seen and every kind of
    /// picture (CMYK, gray, 16-bit) reaches Vision in one form.
    /// - Throws: `PageImageError.cannotDecode` when the picture cannot be
    ///   drawn.
    func flattened(onto background: Background) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw PageImageError.cannotDecode }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: background.gray, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw PageImageError.cannotDecode }
        return flattened
    }
}
