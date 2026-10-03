import CoreGraphics
import Foundation

/// Finds where a PDF page draws images, by reading the page's content
/// stream rather than its pixels.
///
/// The PDF parser asks this so it can run text recognition (OCR) only where
/// a page shows a picture: the text embedded in the PDF is read directly and
/// always kept, and OCR is needed only for text that exists as pixels, such
/// as a scanned page, a photographed sign, or a chart saved as an image
/// (TODO T09).
///
/// Every way a page can place an image is followed: an image XObject drawn
/// with `Do`, an inline image (`BI` … `ID` … `EI`), and images inside form
/// XObjects, which may nest. Each image fills the unit square of the image
/// space that the current transformation matrix maps onto the page, so the
/// scanner tracks that matrix through `q`, `Q`, and `cm`, and through each
/// form's own `/Matrix`.
///
/// Clipping paths are not followed, so an image clipped to part of itself
/// is reported at its full size. A caller that renders the page there, as the
/// parser does, still sees only what the page shows.
enum PDFPageImageScanner {
    /// How deeply form XObjects may nest before the scanner stops entering
    /// them. Real documents nest a few levels at most; the limit stops a
    /// damaged file whose form draws itself from recursing forever.
    static let maximumFormDepth = 8

    /// The rectangle each image on `page` occupies, in the page's default
    /// user space (the coordinates of its media box, before the page's
    /// rotation), in the order the page draws them. An image drawn through a
    /// rotated or skewed matrix is reported as the smallest upright
    /// rectangle that holds it. Empty when the page draws no images.
    static func imageRects(on page: CGPDFPage) -> [CGRect] {
        let state = ScanState()
        let contentStream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(contentStream) }
        scan(contentStream, namingResourcesWith: contentStream, state: state)
        return state.imageRects
    }

    // MARK: - Scanning

    /// Runs every operator in `contentStream` through the scanner's
    /// operator table, recording images in `state`. The XObjects that
    /// `contentStream` draws are looked up in `resourceStream`'s resources:
    /// its own, or, for a form without resources, those of the stream that
    /// drew the form.
    private static func scan(
        _ contentStream: CGPDFContentStreamRef,
        namingResourcesWith resourceStream: CGPDFContentStreamRef,
        state: ScanState
    ) {
        let table = makeOperatorTable()
        defer { CGPDFOperatorTableRelease(table) }
        state.resourceStreams.append(resourceStream)
        defer { state.resourceStreams.removeLast() }
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(contentStream, table, info)
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    /// The operators that matter for finding images. Every other operator
    /// is skipped by the scanner without a callback. Each callback recovers
    /// the scan's `ScanState` from the scanner's info pointer, because a C
    /// callback cannot capture it; for the same reason the callbacks name
    /// this type's helpers explicitly instead of capturing `Self`.
    private static func makeOperatorTable() -> CGPDFOperatorTableRef {
        guard let table = CGPDFOperatorTableCreate() else {
            preconditionFailure("Core Graphics could not create a PDF operator table")
        }
        // q: save the graphics state, which includes the matrix.
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            PDFPageImageScanner.state(from: info)?.saveGraphicsState()
        }
        // Q: restore the matrix saved by the matching q.
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            PDFPageImageScanner.state(from: info)?.restoreGraphicsState()
        }
        // cm: concatenate a matrix onto the current transformation matrix.
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = PDFPageImageScanner.state(from: info),
                  let matrix = PDFPageImageScanner.popMatrix(from: scanner) else { return }
            state.concatenate(matrix)
        }
        // Do: draw a named XObject, an image or a form.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = PDFPageImageScanner.state(from: info) else { return }
            PDFPageImageScanner.drawXObject(from: scanner, with: state)
        }
        // EI ends an inline image, which, like an image XObject, fills the
        // unit square under the current matrix.
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            PDFPageImageScanner.state(from: info)?.recordImage()
        }
        return table
    }

    /// The scan state that `info` points to.
    private static func state(from info: UnsafeMutableRawPointer?) -> ScanState? {
        guard let info else { return nil }
        return Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
    }

    /// The six operands of `cm` (or of a form's `/Matrix`) as a transform.
    /// The scanner's stack holds them last-first, so `f` is popped first.
    /// Nil when an operand is missing or is not a number.
    private static func popMatrix(from scanner: CGPDFScannerRef) -> CGAffineTransform? {
        var values = [CGPDFReal](repeating: 0, count: 6)
        for index in stride(from: 5, through: 0, by: -1) {
            guard CGPDFScannerPopNumber(scanner, &values[index]) else { return nil }
        }
        return CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]
        )
    }

    /// Handles `Do`: records an image XObject, or scans a form XObject's
    /// own content with the form's matrix applied. Other XObjects
    /// (PostScript, or a damaged entry) draw no image.
    private static func drawXObject(from scanner: CGPDFScannerRef, with state: ScanState) {
        var namePointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
        let contentStream = state.resourceStreams.last ?? CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }

        switch name(for: "Subtype", in: dictionary) {
        case "Image":
            state.recordImage()
        case "Form":
            scanForm(stream, dictionary: dictionary, parent: contentStream, with: state)
        default:
            break
        }
    }

    /// Scans a form XObject's content as part of the page: its `/Matrix`
    /// maps form space onto the space the form was drawn in, and its
    /// graphics state is restored afterwards, as `Do` requires. A form
    /// without its own `/Resources` uses the resources of the stream that
    /// draws it (`parent`), as older PDFs expect.
    private static func scanForm(
        _ stream: CGPDFStreamRef,
        dictionary: CGPDFDictionaryRef,
        parent: CGPDFContentStreamRef,
        with state: ScanState
    ) {
        guard state.formDepth < maximumFormDepth else { return }

        var resources: CGPDFDictionaryRef?
        let hasOwnResources = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        // A stream needs some dictionary as its resources; the form's own
        // dictionary stands in when it has none, and lookups then go to
        // the parent stream instead (see `scan`).
        let formStream = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(formStream) }

        state.saveGraphicsState()
        state.formDepth += 1
        if let matrix = formMatrix(in: dictionary) {
            state.concatenate(matrix)
        }
        scan(formStream, namingResourcesWith: hasOwnResources ? formStream : parent, state: state)
        state.formDepth -= 1
        state.restoreGraphicsState()
    }

    /// A form's `/Matrix`, or nil when it has none (the identity) or the
    /// entry is not six numbers.
    private static func formMatrix(in dictionary: CGPDFDictionaryRef) -> CGAffineTransform? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array,
              CGPDFArrayGetCount(array) == 6 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 6)
        for index in 0..<6 {
            guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil }
        }
        return CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]
        )
    }

    /// The name stored under `key` in `dictionary`, such as "Image" for
    /// `/Subtype /Image`; nil when the entry is missing or not a name.
    private static func name(for key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    // MARK: - State

    /// What the scan has learned so far: the current transformation matrix,
    /// the matrices saved by `q`, how deep inside forms it is, and the
    /// images found. A class, so the operator callbacks can reach it
    /// through the scanner's info pointer.
    private final class ScanState {
        /// The current transformation matrix: image or form space to the
        /// page's default user space.
        var matrix = CGAffineTransform.identity
        /// Matrices saved by `q` (and around each form), restored by `Q`.
        var savedMatrices: [CGAffineTransform] = []
        /// How many form XObjects enclose the operator being scanned.
        var formDepth = 0
        /// For each stream being scanned, outermost first, the content
        /// stream whose resources name the XObjects it draws.
        var resourceStreams: [CGPDFContentStreamRef] = []
        /// Each image's rectangle in default user space, in drawing order.
        var imageRects: [CGRect] = []

        /// `q`: remember the current matrix.
        func saveGraphicsState() {
            savedMatrices.append(matrix)
        }

        /// `Q`: return to the matrix the matching `q` saved. An unbalanced
        /// `Q`, which damaged files contain, leaves the matrix as it is.
        func restoreGraphicsState() {
            guard let saved = savedMatrices.popLast() else { return }
            matrix = saved
        }

        /// `cm`: the new matrix maps through `transform` first, then
        /// through the current matrix.
        func concatenate(_ transform: CGAffineTransform) {
            matrix = transform.concatenating(matrix)
        }

        /// Records an image, which always fills the unit square of image
        /// space. An image squeezed to no area (a degenerate matrix) shows
        /// nothing and is not recorded.
        func recordImage() {
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(matrix).standardized
            guard rect.width > 0, rect.height > 0, rect.isFinite else { return }
            imageRects.append(rect)
        }
    }
}

private extension CGRect {
    /// Whether every coordinate is a finite number, as a malformed matrix
    /// with an infinite or NaN entry would not give.
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
