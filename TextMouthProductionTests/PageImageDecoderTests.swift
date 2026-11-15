import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// Decoding an untrusted picture for text recognition (FMT34), within the
/// limits every decode passes: only the common kinds, judged by the bytes;
/// a declared size checked before anything is decoded; the EXIF
/// orientation applied; the size decoded capped; and the page flattened onto
/// an opaque background. No test here needs Vision.
final class PageImageDecoderTests: XCTestCase {

    // MARK: - Kinds

    /// PNG, JPEG, HEIC, TIFF, GIF, and WebP are the kinds decoded, by the
    /// identifiers ImageIO gives the bytes.
    func testTheReadableKinds() {
        XCTAssertEqual(
            PageImageDecoding.readableTypes,
            ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif", "org.webmproject.webp"]
        )
    }

    /// A kind ImageIO knows but TextMouth does not decode is refused by the
    /// bytes, whatever the file is named, and named by the system's
    /// description of it.
    func testAKindNotReadIsRefusedByItsBytes() throws {
        let bitmap = try PageImageFixtures.encoded(PageImageFixtures.picture(width: 40, height: 30), as: .bmp)
        let named = try PageImageFixtures.write(bitmap, named: "letter.png", for: self)

        XCTAssertThrowsError(try PageImageSource(url: named)) { error in
            guard case PageImageError.unreadableKind(let kind) = error else {
                return XCTFail("A bitmap named .png should be refused as its own kind, not \(error)")
            }
            XCTAssertEqual(kind, UTType.bmp.localizedDescription ?? PageImageWording.unnamedKind)
            XCTAssertFalse(kind.isEmpty)
        }
    }

    /// Bytes in which ImageIO finds no picture, and an empty file, are no
    /// picture.
    func testBytesThatHoldNoPictureAreRefused() throws {
        for (name, bytes) in [("noise.jpg", Data("This is a letter, not a picture of one.".utf8)), ("empty.png", Data())] {
            let url = try PageImageFixtures.write(bytes, named: name, for: self)
            XCTAssertThrowsError(try PageImageSource(url: url), name) { error in
                XCTAssertEqual(error as? PageImageError, .notAPicture, name)
            }
            XCTAssertThrowsError(try PageImageSource(data: bytes), name) { error in
                XCTAssertEqual(error as? PageImageError, .notAPicture, name)
            }
        }
    }

    // MARK: - A Declared Size

    /// A small file that claims a vast picture is refused by its header,
    /// before anything is decoded: a PNG of 12,000 by 10,000 pixels, 120
    /// megapixels, in a few kilobytes.
    func testAPictureClaimingMoreThanTheLimitIsRefusedBeforeDecoding() throws {
        let vast = try PageImageFixtures.pngClaiming(width: 12_000, height: 10_000)
        XCTAssertLessThan(vast.count, 100_000, "the fixture is a small file")
        let source = try PageImageSource(data: vast)

        XCTAssertThrowsError(try source.decodedPage(at: XCTUnwrap(source.pageIndexes.first))) { error in
            XCTAssertEqual(error as? PageImageError, .tooLarge(width: 12_000, height: 10_000))
        }
    }

    /// The limit is 100 megapixels exactly, a size of nothing is no picture,
    /// and no declared size overflows the count.
    func testTheDeclaredSizeLimit() {
        XCTAssertNoThrow(try PageImageDecoding.checkDeclaredSize(width: 10_000, height: 10_000))
        XCTAssertNoThrow(try PageImageDecoding.checkDeclaredSize(width: 1, height: 1))
        let cases: [(width: Int, height: Int, error: PageImageError)] = [
            (10_000, 10_001, .tooLarge(width: 10_000, height: 10_001)),
            (Int.max, Int.max, .tooLarge(width: Int.max, height: Int.max)),
            (0, 500, .cannotDecode),
            (500, -1, .cannotDecode),
        ]
        for size in cases {
            XCTAssertThrowsError(try PageImageDecoding.checkDeclaredSize(width: size.width, height: size.height)) { error in
                XCTAssertEqual(error as? PageImageError, size.error, "\(size.width) by \(size.height)")
            }
        }
    }

    /// The size decoded is the picture's own up to 16 megapixels, and else
    /// the size that scales its area down to that, its proportions kept, so
    /// a tall strip keeps its width.
    func testTheDecodedSizeCapsTheAreaNotTheSide() {
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 4_032, height: 3_024), 4_032)
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 800, height: 12_000), 12_000)
        let scaled = PageImageDecoding.decodedLongestSide(width: 8_064, height: 6_048)
        XCTAssertEqual(scaled, Int((8_064 * (16_000_000.0 / (8_064.0 * 6_048.0)).squareRoot()).rounded(.up)))
        let shorter = Double(scaled) * 6_048 / 8_064
        XCTAssertLessThanOrEqual(Double(scaled) * shorter, 16_010_000, "the area decoded stays at the cap")
    }

    /// A picture larger than the decoded cap is decoded smaller, its
    /// proportions kept.
    func testALargePictureIsDecodedSmaller() throws {
        let large = try PageImageFixtures.encoded(PageImageFixtures.picture(width: 5_000, height: 4_000), as: .jpeg)
        let source = try PageImageSource(data: large)

        let page = try source.decodedPage(at: 0).image

        XCTAssertLessThanOrEqual(page.width * page.height, PageImageDecoding.decodedPixels + 10_000)
        XCTAssertEqual(Double(page.width) / Double(page.height), 1.25, accuracy: 0.01)
    }

    // MARK: - Orientation

    /// A photograph stored on its side with an EXIF orientation is decoded
    /// upright: its sides exchanged, and its top where the tag says.
    func testTheEXIFOrientationIsApplied() throws {
        // Stored 300 wide and 200 tall, dark on its left: orientation 6 turns
        // it a quarter clockwise, so it shows 200 wide, 300 tall, dark on top.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return XCTFail("no context") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 200))
        let stored = try XCTUnwrap(context.makeImage())
        let tagged = try PageImageFixtures.encoded(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])

        let page = try PageImageSource(data: tagged).decodedPage(at: 0).image

        XCTAssertEqual(page.width, 200)
        XCTAssertEqual(page.height, 300)
        XCTAssertLessThan(try PageImageFixtures.gray(of: page, x: 100, y: 10), 60, "the stored left edge is the top")
        XCTAssertGreaterThan(try PageImageFixtures.gray(of: page, x: 100, y: 290), 200, "the bottom is the stored right")
    }

    // MARK: - Flattening

    /// Dark print on a transparent picture is drawn onto white, and the
    /// transparency onto the background asked for; an opaque picture has no
    /// alpha to flatten.
    func testATransparentPictureIsFlattenedOntoTheBackgroundAskedFor() throws {
        let clear = try PageImageFixtures.picture(width: 200, height: 100, lines: ["Ferry"], fontSize: 40, ground: nil)
        let decoded = try PageImageSource(data: PageImageFixtures.encoded(clear, as: .png)).decodedPage(at: 0)
        XCTAssertTrue(decoded.hasAlpha)

        let onWhite = try decoded.flattened(onto: .white)
        let onBlack = try decoded.flattened(onto: .black)

        XCTAssertGreaterThanOrEqual(try PageImageFixtures.gray(of: onWhite, x: 190, y: 95), 250)
        XCTAssertLessThanOrEqual(try PageImageFixtures.gray(of: onBlack, x: 190, y: 95), 5)
        for flattened in [onWhite, onBlack] {
            XCTAssertEqual(flattened.alphaInfo, .noneSkipLast)
            XCTAssertEqual(flattened.width, 200)
            XCTAssertEqual(flattened.height, 100)
        }
        let opaque = try PageImageSource(data: PageImageFixtures.encoded(PageImageFixtures.picture(width: 20, height: 20), as: .jpeg))
        XCTAssertFalse(try opaque.decodedPage(at: 0).hasAlpha)
        // The fixtures' opaque PNGs decode without alpha too, so the reader's
        // tests never read one of them again on black.
        XCTAssertFalse(try PageImageSource(data: PageImageFixtures.plainPage()).decodedPage(at: 0).hasAlpha)
    }

    // MARK: - Pages

    /// Every picture of a TIFF is a page; of a GIF, and of a TIFF inside an
    /// archive, only the main picture is.
    func testATIFFsPicturesArePagesAndAnotherKindHasOne() throws {
        let frames = try (0..<3).map { _ in try PageImageFixtures.picture(width: 30, height: 20) }
        let tiff = try PageImageFixtures.encoded(frames, as: .tiff)
        let gif = try PageImageFixtures.encoded(frames, as: .gif)

        let file = try PageImageSource(url: PageImageFixtures.write(tiff, named: "three.tiff", for: self))
        XCTAssertEqual(file.typeIdentifier, UTType.tiff.identifier)
        XCTAssertEqual(file.pageIndexes, [0, 1, 2])
        XCTAssertEqual(try PageImageSource(url: PageImageFixtures.write(gif, named: "three.gif", for: self)).pageIndexes, [0])
        XCTAssertEqual(try PageImageSource(data: tiff).pageIndexes, [0], "an archive's picture is one page")
    }

    /// A TIFF of more pages than TextMouth reads in one book is refused
    /// (here with a limit of 3, the book's being 2,000), and one of exactly
    /// the limit is not.
    func testATIFFOfTooManyPagesIsRefused() throws {
        let tiny = try PageImageFixtures.picture(width: 2, height: 2)
        let pages = Array(repeating: tiny, count: 4)
        let url = try PageImageFixtures.write(try PageImageFixtures.encoded(pages, as: .tiff), named: "many.tiff", for: self)

        XCTAssertThrowsError(try PageImageSource(url: url, maximumPages: 3)) { error in
            XCTAssertEqual(error as? PageImageError, .tooManyPages(4, .picture))
        }
        XCTAssertEqual(try PageImageSource(url: url, maximumPages: 4).pageIndexes, [0, 1, 2, 3])
    }

    // MARK: - The Samples

    /// The picture samples decode as their kinds, at their size, the
    /// transparent PNG with transparency and the TIFF as two pages. The HEIC
    /// is opaque, as it says, though its decoder gives it an alpha channel.
    func testTheSamplesDecode() throws {
        let samples: [(path: String, type: String, pages: Int, alpha: Bool?)] = [
            ("png/page-one.png", "public.png", 1, false),
            ("png/page-one-transparent.png", "public.png", 1, true),
            ("jpeg/page-one.jpg", "public.jpeg", 1, false),
            ("heic/page-one.heic", "public.heic", 1, false),
            ("tiff-multipage/two-pages.tiff", "public.tiff", 2, false),
        ]
        for sample in samples {
            let source = try PageImageSource(url: copyOfFormatSample(sample.path))
            XCTAssertEqual(source.typeIdentifier, sample.type, sample.path)
            XCTAssertEqual(source.pageIndexes.count, sample.pages, sample.path)
            let page = try source.decodedPage(at: XCTUnwrap(source.pageIndexes.first, sample.path))
            XCTAssertEqual(page.image.width, 1_224, sample.path)
            XCTAssertEqual(page.image.height, 1_584, sample.path)
            if let alpha = sample.alpha {
                XCTAssertEqual(page.hasAlpha, alpha, sample.path)
            }
        }
    }
}
