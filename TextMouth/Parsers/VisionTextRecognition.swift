import CoreGraphics
import Foundation
import Vision

// MARK: - Recognized Lines

/// One line of text that Vision's text recognition found in a picture, with
/// its box as fractions of the picture's width and height, the origin at the
/// bottom left, as Vision reports boxes.
struct RecognizedTextLine: Equatable, Sendable {
    /// The line's text as recognized.
    var text: String
    /// The line's box, as fractions of the picture's width and height with
    /// the origin at the bottom left: a higher `midY` is higher in the picture.
    var normalizedBounds: CGRect
}

// MARK: - The Recognition

/// The one text recognition TextMouth runs: Vision's accurate recognizer,
/// with language correction, in the languages Vision reads when none are
/// named. A scanned PDF's pages (`VisionPDFTextRecognizer`) and pictures of
/// pages (`PageImageReader`, FMT34) are both read through it, so both read
/// text the same way and in the same order.
enum VisionTextRecognition {
    /// Vision error codes that mean recognition cannot run in this process
    /// at all (its model or request is missing or unsupported here), as
    /// opposed to failing on one picture.
    static let unavailableCodes: Set<VNErrorCode> = [
        .notImplemented, .invalidModel, .unsupportedRevision, .unsupportedRequest,
        .unsupportedComputeStage, .unsupportedComputeDevice
    ]

    /// The lines of text in `image`, in reading order (`readingOrder(_:)`).
    /// An observation Vision gives no candidate for is left out.
    /// - Throws: `PDFTextRecognitionError.unavailable` when recognition
    ///   cannot run in this process, or `.failed` when it failed on this
    ///   picture (`recognitionError(for:)`).
    static func lines(in image: CGImage) throws -> [RecognizedTextLine] {
        // Without a completion handler, perform(_:) runs the request
        // synchronously and leaves the observations on the request.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw recognitionError(for: error)
        }

        return readingOrder(request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(text: candidate.string, normalizedBounds: observation.boundingBox)
        }
    }

    /// Vision's observations top to bottom, then left to right where two
    /// lines sit at almost the same height. Vision's boxes are normalized
    /// with the origin at the bottom left, so a higher `midY` is higher on
    /// the page. This is the order the PDF parser has always read OCR text in.
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
        let description = "text recognition failed: \(error.localizedDescription)" // l10n: no (a parser's damage reason)
        let nsError = error as NSError
        if nsError.domain == VNErrorDomain, let code = VNErrorCode(rawValue: nsError.code),
           unavailableCodes.contains(code) {
            return .unavailable(description)
        }
        return .failed(description)
    }
}
