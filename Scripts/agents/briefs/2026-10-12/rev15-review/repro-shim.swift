import Foundation

// A shim that builds REV15's reproduction programs (repro/*.swift) against
// the relocator as the REV15 fixes left it (merged October 12, 2026). The
// programs build relocators with the new text's headings alone, and move a
// book's places with relocate(_:); the fixed relocator takes both texts'
// headings together and the time of the move. Pass this file to
// build-probe.sh as EXTRA:
//
//   EXTRA=<this file> zsh build-probe.sh repro/V9.swift <out>
//
// With no old headings, a skip is found only by the relocator's rules 1
// and 4 (its ID, or the one new heading of its level with its label), so the
// heading programs no longer show what a rebuild does with a skip; the unit
// tests in PlaceRelocatorHeadingTests pass old headings for each case.
extension PlaceRelocator {
    /// A relocator given the new text's headings alone.
    init(oldTexts: [String], newTexts: [String], newHeadings: [Heading]) {
        self.init(oldTexts: oldTexts, newTexts: newTexts, oldHeadings: [], newHeadings: newHeadings)
    }

    /// A relocator given the new text's headings alone.
    init(old: BookWords, new: BookWords, newHeadings: [Heading]) {
        self.init(old: old, new: new, oldHeadings: [], newHeadings: newHeadings)
    }

    /// The places moved at a fixed time.
    func relocate(_ places: Places) -> Outcome {
        relocate(places, movedAt: Date(timeIntervalSince1970: 0))
    }
}
