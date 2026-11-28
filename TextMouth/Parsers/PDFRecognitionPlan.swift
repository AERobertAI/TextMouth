import CoreGraphics

/// Chooses the parts of a PDF page that OCR should read when the page
/// already has embedded text (TODO T09).
///
/// Only pictures can hold text that the page does not embed, so OCR reads
/// the regions where the page draws images, except:
/// - the parts of images outside the shown page (the crop box);
/// - an image that embedded text already largely covers, which is either a
///   background drawn behind the page's text or a scan carrying its own
///   OCR text layer (searchable scans hide that text over the picture), so
///   reading it again would only repeat the page's text, slowly;
/// - regions too small to hold a legible line of text, such as bullets,
///   rules, and icons.
///
/// Images that touch or overlap are read as one region, so a scan stored
/// as strips or tiles is read whole and no picture is read twice.
/// A page without embedded text is not planned here: the parser reads all
/// of it, because a scanned page's text may be drawn in any way.
enum PDFRecognitionPlan {
    /// An image at least this much covered by embedded text lines is taken
    /// to be a background or an already transcribed scan, and is not read.
    /// A full page of body text covers about half of its page; a caption or
    /// a stamp laid over a picture covers a few percent of it.
    static let transcribedCoverage: CGFloat = 0.25
    /// The shortest side, in points, of a region worth reading: about the
    /// height of one line of small print.
    static let minimumSide: CGFloat = 12
    /// The smallest region worth reading, as a share of the shown page's
    /// area (on a letter-size page, about 60 by 16 points).
    static let minimumAreaFraction: CGFloat = 0.002
    /// At most this many regions are read on one page; a page with more
    /// (a map strewn with labelled pictures, say) is read as one region
    /// holding them all, which costs one recognition instead of dozens.
    static let maximumRegions = 12
    /// Images closer than this many points are treated as touching.
    static let touchingTolerance: CGFloat = 1
    /// Beyond this many images on one page, they are read as one region
    /// holding them all without being merged one by one, which would take
    /// time growing with the square of their number.
    static let maximumImagesToMerge = 256

    /// The regions of a page to read, in the order the page shows them:
    /// top to bottom, then left to right.
    /// - Parameters:
    ///   - images: where the page draws images, in default user space.
    ///   - visibleBounds: the part of the page that is shown.
    ///   - embeddedLines: the bounds of the page's embedded text lines.
    ///   - rotation: the page's `/Rotate`, which decides what is "top".
    static func regions(
        images: [CGRect],
        visibleBounds: CGRect,
        embeddedLines: [CGRect],
        rotation: Int
    ) -> [CGRect] {
        let shown = images
            .map { $0.intersection(visibleBounds) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let untranscribed = shown.filter {
            PDFPageGeometry.coveredFraction(of: $0, by: embeddedLines) < transcribedCoverage
        }
        let minimumArea = visibleBounds.width * visibleBounds.height * minimumAreaFraction
        let merged = untranscribed.count > maximumImagesToMerge
            ? [union(of: untranscribed)]
            : mergedTouching(untranscribed)
        let legible = merged.filter {
            min($0.width, $0.height) >= minimumSide && $0.width * $0.height >= minimumArea
        }
        guard legible.count <= maximumRegions else {
            return [union(of: legible)]
        }
        return PDFPageGeometry.inReadingOrder(legible, rotation: rotation) { $0 }
    }

    /// `rects` with every group of touching or overlapping rectangles
    /// replaced by the smallest rectangle holding the group. Each new
    /// rectangle absorbs every earlier region it touches, repeatedly,
    /// because a union can grow to touch regions that neither part did.
    static func mergedTouching(_ rects: [CGRect]) -> [CGRect] {
        var regions: [CGRect] = []
        for rect in rects {
            var merged = rect
            var absorbedAny = true
            while absorbedAny {
                absorbedAny = false
                for index in regions.indices.reversed() where touches(merged, regions[index]) {
                    merged = merged.union(regions.remove(at: index))
                    absorbedAny = true
                }
            }
            regions.append(merged)
        }
        return regions
    }

    /// The smallest rectangle holding every one of `rects`, which must not
    /// be empty.
    private static func union(of rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    }

    /// Whether two rectangles overlap or lie within `touchingTolerance` of
    /// each other.
    private static func touches(_ first: CGRect, _ second: CGRect) -> Bool {
        first.insetBy(dx: -touchingTolerance, dy: -touchingTolerance).intersects(second)
    }
}

/// Geometry shared by the PDF parser's OCR planning and merging, in the
/// page's default user space.
enum PDFPageGeometry {
    /// The share of `rect`'s area that `others` cover, from 0 to 1. Where
    /// several of `others` overlap the same spot it is counted for each, so
    /// the sum is capped at 1; the text lines this measures rarely overlap.
    static func coveredFraction(of rect: CGRect, by others: [CGRect]) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let covered = others.reduce(CGFloat(0)) { total, other in
            let overlap = rect.intersection(other)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        return min(covered / area, 1)
    }

    /// `rect` as the page shows it: turned by the page's rotation into
    /// upright coordinates, where a larger y is higher on the shown page.
    static func upright(_ rect: CGRect, rotation: Int) -> CGRect {
        rect.applying(PDFRegionRendering.uprightTransform(forRotation: rotation)).standardized
    }

    /// `items` in the order the page shows their rectangles (`bounds`): top
    /// to bottom, and left to right among those whose tops are within a
    /// point of each other. Tops are rounded to whole points so the order
    /// is consistent however the comparisons fall.
    static func inReadingOrder<Item>(_ items: [Item], rotation: Int, bounds: (Item) -> CGRect) -> [Item] {
        let keyed = items.map { item -> (item: Item, top: CGFloat, left: CGFloat) in
            let shown = upright(bounds(item), rotation: rotation)
            return (item, shown.maxY.rounded(), shown.minX)
        }
        return keyed
            .sortedStably { $0.top != $1.top ? $0.top > $1.top : $0.left < $1.left }
            .map(\.item)
    }
}
