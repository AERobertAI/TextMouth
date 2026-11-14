import CoreGraphics
import Foundation
import PDFKit
import Vision

// MARK: - Recognized Lines

/// One line of text that optical character recognition (OCR) found on a
/// PDF page, with where it was found.
struct PDFRecognizedLine: Equatable, Sendable {
    /// The line's text as recognized.
    var text: String
    /// The line's bounding box in the page's default user space: the
    /// coordinates of its media box, before the page's rotation, which are
    /// the coordinates PDFKit gives embedded characters.
    var bounds: CGRect
}

/// Why OCR could not read part of a page.
enum PDFTextRecognitionError: Error, Equatable, Sendable {
    /// OCR cannot run in this process at all, so no other page should try.
    case unavailable(String)
    /// OCR could not read this region; other regions may still be read.
    case failed(String)

    /// Why, in words that complete a sentence a reader hears.
    var reason: String {
        switch self {
        case .unavailable(let reason), .failed(let reason):
            return reason
        }
    }
}

// MARK: - Recognizer

/// Recognizes printed text in part of a PDF page. The parser asks it only
/// about regions whose text may exist only as pixels; tests supply their
/// own recognizer to check those decisions without depending on Vision.
protocol PDFPageTextRecognizer: Sendable {
    /// The lines of text in `region` of `page`, in reading order. `region`
    /// and every returned line's bounds use the page's default user space.
    /// - Throws: `PDFTextRecognitionError.unavailable` when OCR cannot run
    ///   at all, or `.failed` when this region could not be read.
    func recognizeLines(in region: CGRect, of page: PDFPage) throws -> [PDFRecognizedLine]
}

/// Recognizes text with the Vision framework's accurate text recognizer,
/// on an upright picture of the region drawn at a resolution suited to OCR.
struct VisionPDFTextRecognizer: PDFPageTextRecognizer {
    /// Vision error codes that mean recognition cannot run in this process
    /// at all (its model or request is missing or unsupported here), as
    /// opposed to failing on one picture.
    static let unavailableCodes: Set<VNErrorCode> = [
        .notImplemented, .invalidModel, .unsupportedRevision, .unsupportedRequest,
        .unsupportedComputeStage, .unsupportedComputeDevice
    ]

    func recognizeLines(in region: CGRect, of page: PDFPage) throws -> [PDFRecognizedLine] {
        guard let cgPage = page.pageRef, let rendering = PDFRegionRendering(page: cgPage, region: region) else {
            throw PDFTextRecognitionError.failed("the page could not be drawn for text recognition")
        }

        // Without a completion handler, perform(_:) runs the request
        // synchronously and leaves the observations on the request.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: rendering.image, options: [:]).perform([request])
        } catch {
            throw Self.recognitionError(for: error)
        }

        return Self.readingOrder(request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return PDFRecognizedLine(
                text: candidate.string,
                bounds: rendering.pageRect(forNormalizedRect: observation.boundingBox)
            )
        }
    }

    /// Vision's observations top to bottom, then left to right where two
    /// lines sit at almost the same height. Vision's boxes are normalized
    /// with the origin at the bottom left, so a higher `midY` is higher on
    /// the page. This is the order the parser has always read OCR text in.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        observations.sortedStably { first, second in
            if abs(first.boundingBox.midY - second.boundingBox.midY) > 0.01 {
                return first.boundingBox.midY > second.boundingBox.midY
            }
            return first.boundingBox.midX < second.boundingBox.midX
        }
    }

    /// The recognition error for an error Vision threw: unavailable when
    /// Vision says it cannot run this request here, failed otherwise.
    /// Vision reports its errors as `NSError`s in `VNErrorDomain` whose
    /// codes are `VNErrorCode` values.
    static func recognitionError(for error: Error) -> PDFTextRecognitionError {
        let description = "text recognition failed: \(error.localizedDescription)"
        let nsError = error as NSError
        if nsError.domain == VNErrorDomain, let code = VNErrorCode(rawValue: nsError.code),
           unavailableCodes.contains(code) {
            return .unavailable(description)
        }
        return .failed(description)
    }
}

// MARK: - Rendering

/// A picture of part of a PDF page for OCR, drawn upright as the page is
/// shown (its `/Rotate` applied) on a white ground, with the means to map
/// boxes in the picture back to the page's default user space.
///
/// The page is drawn with Core Graphics through a transform this type
/// builds itself, rather than through PDFKit's drawing, so the mapping back
/// to user space is exactly the inverse of the mapping used to draw.
struct PDFRegionRendering {
    /// The longest side, in pixels, a picture is drawn at when the region
    /// is small enough to be enlarged that far: about the size at which
    /// Vision reads body text on a full page.
    static let targetLongestSide: CGFloat = 1_600
    /// Pixels per point at least (a full page is drawn at about this) and
    /// at most (enlarging a small region further adds nothing legible).
    static let scaleRange: ClosedRange<CGFloat> = 2...4
    /// No side is drawn longer than this many pixels, whatever the page
    /// size, so a poster-sized page cannot exhaust memory.
    static let maximumSide: CGFloat = 8_000

    /// The picture: white where the page draws nothing.
    let image: CGImage
    /// Maps a point in the picture's pixels to the page's user space.
    private let pixelsToPage: CGAffineTransform

    /// Draws `region` of `page`. Nil when the region is empty or the
    /// picture could not be made.
    init?(page: CGPDFPage, region: CGRect) {
        // User space → upright (shown) space, then → the picture's pixels.
        let upright = Self.uprightTransform(forRotation: Int(page.rotationAngle))
        let shown = region.applying(upright).standardized
        let longest = max(shown.width, shown.height)
        guard longest > 0, longest.isFinite else { return nil }

        let preferred = min(max(Self.targetLongestSide / longest, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let scale = min(preferred, Self.maximumSide / longest)
        let width = Int((shown.width * scale).rounded(.up))
        let height = Int((shown.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }

        let pageToPixels = upright
            .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.concatenate(pageToPixels)
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { return nil }
        self.image = image
        self.pixelsToPage = pageToPixels.inverted()
    }

    /// The page rectangle, in user space, for `rect` given as fractions of
    /// the picture's width and height with the origin at the bottom left,
    /// as Vision reports boxes.
    func pageRect(forNormalizedRect rect: CGRect) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixels = CGRect(
            x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height
        )
        return pixels.applying(pixelsToPage).standardized
    }

    /// The rotation that shows a page upright: `/Rotate` turns the page
    /// clockwise as shown, which in Core Graphics' y-up coordinates is a
    /// turn of the opposite sign. Written out for each quarter turn so the
    /// matrix holds exact zeros and ones; any other angle, which a valid
    /// PDF never has, is treated as no rotation.
    static func uprightTransform(forRotation degrees: Int) -> CGAffineTransform {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        default: return .identity
        }
    }
}
