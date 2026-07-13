import Foundation

/// TextMouth persists and exchanges text positions as UTF-16 offsets. This is
/// the coordinate system used by NSRange, NSRegularExpression, AppKit, and
/// AVSpeechSynthesizer callbacks. Central helpers prevent accidental mixing
/// with Swift's grapheme-cluster `String.count` and `offsetBy:` APIs.
extension String {
    var utf16Length: Int { utf16.count }

    func index(atUTF16Offset offset: Int) -> String.Index {
        let clamped = max(0, min(offset, utf16.count))
        var utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped)
        while let index = String.Index(utf16Index, within: self) {
            return index
        }
        repeat {
            utf16.formIndex(before: &utf16Index)
        } while String.Index(utf16Index, within: self) == nil
        return String.Index(utf16Index, within: self) ?? startIndex
    }

    func utf16Offset(of index: String.Index) -> Int {
        index.utf16Offset(in: self)
    }
}

/// A bidirectional mapping between character offsets in two versions of a text
/// (e.g., before and after a transformation like filtering, insertion, or substitution).
///
/// Each "point" records a position in the target text and the cumulative delta
/// at that position.  To convert target→source: add the delta.
/// To convert source→target: subtract the delta.
///
/// Convention:
///   - "source" = the input text (before transformation)
///   - "target" = the output text (after transformation)
///   - A positive delta means the target is *shorter* (characters were removed)
///   - A negative delta means the target is *longer* (characters were inserted)
struct OffsetMap: Equatable {

    /// A sorted list of (targetPos, cumulativeDelta).
    /// targetPos is the position in the target text where the delta changes.
    /// cumulativeDelta is the total shift at that position.
    /// To recover source position: sourcePos = targetPos + delta
    let points: [(targetPos: Int, cumulativeDelta: Int)]

    /// An identity map — no offset changes.
    static let identity = OffsetMap(points: [])

    /// Whether this map has any offset changes.
    var hasChanges: Bool { !points.isEmpty }

    /// Convert a target-text offset to the corresponding source-text offset.
    /// target + delta = source
    func toSource(_ targetOffset: Int) -> Int {
        guard !points.isEmpty else { return targetOffset }
        return targetOffset + deltaForTargetOffset(targetOffset)
    }

    /// Convert a source-text offset to the corresponding target-text offset.
    /// target = source - delta  (we search for the right delta by walking source positions)
    func toTarget(_ sourceOffset: Int) -> Int {
        guard !points.isEmpty else { return sourceOffset }
        // `points` are sorted by target position, not by source position.
        // Source-side breakpoints can move backward when mixed insertions
        // and deletions occur, so this path intentionally remains linear
        // to preserve the "last target-sorted point whose source position
        // is <= sourceOffset" semantics.
        var delta = 0
        for point in points {
            let sourceAtPoint = point.targetPos + point.cumulativeDelta
            if sourceAtPoint <= sourceOffset {
                delta = point.cumulativeDelta
            } else {
                break
            }
        }
        return max(0, sourceOffset - delta)
    }

    private func deltaForTargetOffset(_ targetOffset: Int) -> Int {
        var low = 0
        var high = points.count

        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].targetPos <= targetOffset {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low > 0 else { return 0 }
        return points[low - 1].cumulativeDelta
    }

    // MARK: - Equatable (synthesized for tuples)

    static func == (lhs: OffsetMap, rhs: OffsetMap) -> Bool {
        guard lhs.points.count == rhs.points.count else { return false }
        for (l, r) in zip(lhs.points, rhs.points) {
            if l.targetPos != r.targetPos || l.cumulativeDelta != r.cumulativeDelta {
                return false
            }
        }
        return true
    }
}


/// Chains multiple `OffsetMap` stages into a single bidirectional mapping.
///
/// Given stages [A, B, C] where:
///   A maps original→filtered, B maps filtered→paused, C maps paused→modified
/// then `toModified(x)` computes C.toTarget(B.toTarget(A.toTarget(x)))
/// and  `toOriginal(x)` computes A.toSource(B.toSource(C.toSource(x)))
struct ComposedOffsetMap: Equatable {
    /// The stages in source→target order.
    let stages: [OffsetMap]

    /// Convert an offset in the original (source-most) text to the final (target-most) text.
    func toModified(_ originalOffset: Int) -> Int {
        stages.reduce(originalOffset) { $1.toTarget($0) }
    }

    /// Convert an offset in the final (target-most) text back to the original (source-most) text.
    func toOriginal(_ modifiedOffset: Int) -> Int {
        stages.reversed().reduce(modifiedOffset) { $1.toSource($0) }
    }

    /// Whether any stage has offset changes.
    var hasChanges: Bool { stages.contains(where: { $0.hasChanges }) }
}
