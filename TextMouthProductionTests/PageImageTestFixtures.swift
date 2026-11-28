import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Pictures, multi-page TIFFs, and comic book archives made in memory for the
/// tests of pictures of pages (FMT34), and a recognizer that answers from a
/// script, so the reader's decisions are tested without Vision. Nothing
/// here traps: every failure to make a fixture throws.
enum PageImageFixtures {
    /// Why a fixture could not be made.
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Pictures

    /// A picture `width` by `height` pixels: `ground` everywhere (clear when
    /// nil), with each of `lines` drawn in `ink`, `fontSize` pixels tall,
    /// one under another from the top, in bold Helvetica. A picture with a
    /// ground has no alpha channel, so it is written and decoded opaque, as a
    /// scan or a photograph is; only a clear one has one.
    static func picture(
        width: Int = 1_200, height: Int = 900, lines: [String] = [], fontSize: CGFloat = 64,
        ground: CGColor? = CGColor(gray: 1, alpha: 1), ink: CGColor = CGColor(gray: 0, alpha: 1)
    ) throws -> CGImage {
        let alpha: CGImageAlphaInfo = ground == nil ? .premultipliedLast : .noneSkipLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: alpha.rawValue
        ) else { throw FixtureError(description: "no drawing context") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        if let ground {
            context.setFillColor(ground)
            context.fill(bounds)
        }
        let font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink) ?? .black])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: fontSize, y: CGFloat(height) - fontSize * 2 - CGFloat(index) * fontSize * 1.6)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw FixtureError(description: "no picture made") }
        return image
    }

    /// `images` written as one file of `type`, each with `properties` (an
    /// EXIF orientation, say): a TIFF or GIF of several pictures when given
    /// several.
    static func encoded(_ images: [CGImage], as type: UTType, properties: [CFString: Any]? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil) else {
            throw FixtureError(description: "ImageIO cannot write \(type.identifier)")
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError(description: "ImageIO could not finish \(type.identifier)")
        }
        return data as Data
    }

    /// `image` written as one file of `type`.
    static func encoded(_ image: CGImage, as type: UTType, properties: [CFString: Any]? = nil) throws -> Data {
        try encoded([image], as: type, properties: properties)
    }

    /// A complete, valid PNG of `width` by `height` black pixels of one bit
    /// each, which compresses to a few kilobytes: what a small hostile file
    /// that claims a vast picture looks like. It is whole, since ImageIO
    /// reads no size from a PNG whose picture data ends early (measured), and
    /// it must never be decoded: 120 megapixels would take hundreds of MB.
    static func pngClaiming(width: Int, height: Int) throws -> Data {
        /// The four bytes of `value`, most significant first.
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        /// A PNG chunk of `type` holding `body`, with its CRC.
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
        }
        // Each row: its filter byte (none) and its pixels, all zeros.
        let rows = Data(count: height * (1 + (width + 7) / 8))
        // Foundation's zlib is raw DEFLATE: the stream gets zlib's header and
        // its Adler-32, which for zeros is a count of them over a sum of one.
        let deflated = try (rows as NSData).compressed(using: .zlib) as Data
        let adler = UInt32(rows.count % 65_521) << 16 | 1
        let stream: [UInt8] = [0x78, 0x9C] + [UInt8](deflated) + bigEndian(adler)
        // Bit depth 1, gray, deflate, no filter method, not interlaced.
        let form: [UInt8] = [1, 0, 0, 0, 0]
        let header = bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + form
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let chunks = chunk("IHDR", header) + chunk("IDAT", stream) + chunk("IEND", [])
        return Data(signature + chunks)
    }

    /// The CRC-32 PNG's chunks carry (ISO 3309), computed bit by bit.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The gray level, from 0 to 255, of the pixel at `x`, `y` (from the top
    /// left) of `image`, read from an 8-bit gray copy of it.
    static func gray(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel: UInt8 = 0
        // The context draws into the byte it is given, so it lives only
        // while that byte's address is valid.
        try withUnsafeMutableBytes(of: &pixel) { byte in
            guard let context = CGContext(
                data: byte.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw FixtureError(description: "no gray context") }
            // Drawn so that the wanted pixel falls on the context's only one.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return pixel
    }

    // MARK: - Files

    /// `data` written into a new sandbox folder of `test` as `name`.
    static func write(_ data: Data, named name: String, for test: XCTestCase) throws -> URL {
        let url = try test.makeSandboxDirectory("PageImage").appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A comic book archive named `name` in a new sandbox folder of `test`,
    /// holding `entries` in that order.
    static func comicArchive(
        named name: String = "book.cbz", _ entries: [TestZIPEntry], for test: XCTestCase,
        compressionMethod: CompressionMethod = .none
    ) throws -> URL {
        let zip = try makeTemporaryZip(prefix: "pageimage", orderedEntries: entries, compressionMethod: compressionMethod)
        let url = try test.makeSandboxDirectory("PageImageArchive").appendingPathComponent(name)
        try FileManager.default.moveItem(at: zip, to: url)
        return url
    }

    /// A ComicInfo.xml holding `body` inside its root element.
    static func comicInfo(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        \(body)
        </ComicInfo>
        """.utf8)
    }

    /// A small PNG picture, for an archive's page whose text the scripted
    /// recognizer gives.
    static func plainPage() throws -> Data {
        try encoded(picture(width: 64, height: 48), as: .png)
    }

    // MARK: - Recognized Lines

    /// One recognized line of `text` whose box spans most of the picture's
    /// width from `left`, its top at `top`, as a fraction of the picture's
    /// height from its foot, `height` tall.
    static func line(_ text: String, top: CGFloat, height: CGFloat = 0.04, left: CGFloat = 0.1) -> RecognizedTextLine {
        RecognizedTextLine(text: text, normalizedBounds: CGRect(x: left, y: top - height, width: 0.8, height: height))
    }

    /// Recognized lines of `texts`, one under another from `top` down, a
    /// usual line's height apart: one paragraph.
    static func paragraph(_ texts: [String], startingAt top: CGFloat = 0.9) -> [RecognizedTextLine] {
        texts.enumerated().map { index, text in line(text, top: top - CGFloat(index) * 0.05) }
    }
}
