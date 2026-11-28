import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// Decoding an untrusted picture for text recognition (FMT34), within the
/// limits every decode passes: only the common kinds, judged by the bytes;
/// a declared size checked before anything is decoded; the EXIF
/// orientation applied; the size decoded capped, by each device's limits;
/// and the page flattened onto an opaque background. No test here needs
/// Vision.
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

    /// On the Mac the size decoded is the picture's own up to 16
    /// megapixels, and else the size that scales its area down to that, its
    /// proportions kept, so a tall strip keeps its width: up to the most a
    /// picture may declare, never a fraction of its sides.
    func testTheDecodedSizeCapsTheAreaNotTheSide() {
        let mac = PageImageDecoding.Limits.mac
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 4_032, height: 3_024, within: mac), 4_032)
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 800, height: 12_000, within: mac), 12_000)
        let scaled = PageImageDecoding.decodedLongestSide(width: 8_064, height: 6_048, within: mac)
        XCTAssertEqual(scaled, Int((8_064 * (16_000_000.0 / (8_064.0 * 6_048.0)).squareRoot()).rounded(.up)))
        let shorter = Double(scaled) * 6_048 / 8_064
        XCTAssertLessThanOrEqual(Double(scaled) * shorter, 16_010_000, "the area decoded stays at the cap")
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 10_000, height: 10_000, within: mac), 4_000)
    }

    /// A picture larger than the decoded cap is decoded smaller, its
    /// proportions kept.
    func testALargePictureIsDecodedSmaller() throws {
        let large = try PageImageFixtures.encoded(PageImageFixtures.picture(width: 5_000, height: 4_000), as: .jpeg)
        let source = try PageImageSource(data: large)

        let page = try source.decodedPage(at: 0).image

        XCTAssertLessThanOrEqual(page.width * page.height, PageImageDecoding.Limits.thisDevice.decodedPixels + 10_000)
        XCTAssertEqual(Double(page.width) / Double(page.height), 1.25, accuracy: 0.01)
    }

    // MARK: - Each Device's Limits

    /// The Mac decodes a page at up to 16 megapixels, the iPhone at up to 4,
    /// read at a fraction of a larger picture's sides, and the Mac's tests
    /// run with the Mac's.
    func testEachDeviceHasItsLimits() {
        XCTAssertEqual(PageImageDecoding.Limits.mac, .init(decodedPixels: 16_000_000, readsAtAFraction: false))
        XCTAssertEqual(PageImageDecoding.Limits.phone, .init(decodedPixels: 4_000_000, readsAtAFraction: true))
        XCTAssertEqual(PageImageDecoding.readingFractions, [2, 4, 8])
        #if os(macOS)
        XCTAssertEqual(PageImageDecoding.Limits.thisDevice, .mac)
        #endif
    }

    /// On the iPhone a picture of more than 4 megapixels is asked for one
    /// pixel under its side over the least of 2, 4, and 8 that brings it
    /// within them, rounded down: a 12-megapixel photograph at half its
    /// sides, a 16-megapixel one too, a 24- or 48-megapixel one at a quarter,
    /// and the most a picture may declare at an eighth. A tall strip keeps
    /// its width, and a picture of 4 megapixels or fewer, as a phone's
    /// screenshot is, is decoded at its own size.
    func testTheiPhoneReadsALargerPictureAtAFractionOfItsSides() {
        let cases: [(width: Int, height: Int, side: Int)] = [
            (2_000, 2_000, 2_000),
            (1_179, 2_556, 2_556),
            (4_032, 3_024, 2_015),
            (4_033, 3_025, 2_015),
            (4_608, 3_456, 2_303),
            (5_712, 4_284, 1_427),
            (8_064, 6_048, 2_015),
            (10_000, 10_000, 1_249),
            (800, 12_000, 5_999),
            (100_000, 1_000, 12_499),
        ]
        for size in cases {
            XCTAssertEqual(
                PageImageDecoding.decodedLongestSide(width: size.width, height: size.height, within: .phone), size.side,
                "\(size.width) by \(size.height)"
            )
        }
    }

    /// When even an eighth of its sides holds more than the cap, a picture
    /// is scaled down to the cap: here a cap of 100 pixels, which no device
    /// has, so that an eighth of 200 by 200 pixels, 25 by 25, is too many.
    func testAPictureTooLargeForAnEighthIsScaledToTheCap() {
        let limits = PageImageDecoding.Limits(decodedPixels: 100, readsAtAFraction: true)
        XCTAssertEqual(PageImageDecoding.decodedLongestSide(width: 200, height: 200, within: limits), 10)
    }

    /// Decoded within the iPhone's limits, a 12-megapixel photograph comes
    /// out a pixel under half its sides, 3 megapixels, as JPEG, PNG, and
    /// TIFF (not HEIC: ImageIO writes one only with a HEVC encoder, which a
    /// test machine may lack), and upright when its EXIF says it was taken
    /// on its side; the Mac's limits keep it whole.
    func testAPhotographDecodedWithinTheiPhonesLimitsComesOutAtHalfItsSides() throws {
        let photograph = try PageImageFixtures.picture(width: 4_032, height: 3_024, lines: ["Ferry"], fontSize: 200)
        for type in [UTType.jpeg, .png, .tiff] {
            let source = try PageImageSource(data: PageImageFixtures.encoded(photograph, as: type))
            let page = try source.decodedPage(at: 0, within: .phone).image
            XCTAssertEqual(page.width, 2_015, type.identifier)
            XCTAssertEqual(page.height, 1_511, type.identifier)
            XCTAssertEqual(try source.decodedPage(at: 0, within: .mac).image.width, 4_032, type.identifier)
        }
        let onItsSide = try PageImageFixtures.encoded(photograph, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let upright = try PageImageSource(data: onItsSide).decodedPage(at: 0, within: .phone).image
        XCTAssertEqual(upright.width, 1_511)
        XCTAssertEqual(upright.height, 2_015)
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
            XCTAssertEqual(error as? PageImageError, .tooManyPages(4))
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
