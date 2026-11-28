import XCTest
@testable import TextMouth

/// The join of a KF8 document from its skeleton and fragments
/// (`KF8Layout.markup(of:in:anchors:)`), proved on parts made directly from
/// places, so that every order of insertion can be tried, and its cost
/// measured on the many fragments a hostile book could name.
final class KF8LayoutTests: XCTestCase {

    // MARK: - Helpers

    /// The layout of one part: `skeleton` and `fragments` (an insert place
    /// and a range of the text each) of a text.
    private func part(
        skeleton: Range<Int>, _ fragments: [(insert: Int, range: Range<Int>)]
    ) -> KF8Layout.Part {
        KF8Layout.Part(
            skeleton: skeleton,
            fragments: fragments.enumerated().map {
                KF8Layout.Fragment(insertOffset: $0.element.insert, identifier: $0.offset, range: $0.element.range)
            }
        )
    }

    /// The part joined, as a string.
    private func joined(
        _ text: String, skeleton: Range<Int>, _ fragments: [(insert: Int, range: Range<Int>)],
        anchors: [KF8Layout.Anchor] = []
    ) throws -> String {
        let bytes = Array(text.utf8)
        let layout = KF8Layout(parts: [part(skeleton: skeleton, fragments)])
        return String(decoding: try layout.markup(of: layout.parts[0], in: bytes, anchors: anchors), as: UTF8.self)
    }

    // MARK: - The order of insertion

    func testFragmentsGoBackWhereTheirPlacesSayInTheOrderTheyAreRead() throws {
        // The skeleton is AAAABBBB; x goes in at 4, then y at 6, which is after x
        // (places are counted with the earlier fragments in).
        XCTAssertEqual(try joined("AAAABBBBxxyy", skeleton: 0..<8, [(4, 8..<10), (6, 10..<12)]), "AAAAxxyyBBBB")
        // y at 4 goes in front of x.
        XCTAssertEqual(try joined("AAAABBBBxxyy", skeleton: 0..<8, [(4, 8..<10), (4, 10..<12)]), "AAAAyyxxBBBB")
        // At the very start and at the very end.
        XCTAssertEqual(try joined("AAAAxxyy", skeleton: 0..<4, [(0, 4..<6), (6, 6..<8)]), "xxAAAAyy")
    }

    func testAFragmentCanGoInsideAnEarlierFragmentOrInFrontOfIt() throws {
        // x is AAxxxxAA; y goes inside x, at 4.
        XCTAssertEqual(try joined("AAAAxxxxyy", skeleton: 0..<4, [(2, 4..<8), (4, 8..<10)]), "AAxxyyxxAA")
        // y goes in front of x, which is already in.
        XCTAssertEqual(try joined("AAAAxxyy", skeleton: 0..<4, [(4, 4..<6), (0, 6..<8)]), "yyAAAAxx")
        XCTAssertEqual(try joined("AAAAxxyy", skeleton: 0..<4, [(2, 4..<6), (2, 6..<8)]), "AAyyxxAA")
    }

    func testTheSkeletonAndFragmentsOfAPartThatDoesNotStartTheTextAreOffsetByIt() throws {
        // A second part: its skeleton is at 10, so its places count from 10.
        let text = "0123456789AAAABBBBxx"
        XCTAssertEqual(try joined(text, skeleton: 10..<18, [(14, 18..<20)]), "AAAAxxBBBB")
    }

    func testEmptyPiecesAreNoTrouble() throws {
        XCTAssertEqual(try joined("xx", skeleton: 0..<0, [(0, 0..<2)]), "xx")
        XCTAssertEqual(try joined("xx", skeleton: 0..<0, [(0, 0..<0), (0, 0..<2), (0, 2..<2)]), "xx")
        XCTAssertEqual(try joined("AB", skeleton: 0..<2, []), "AB")
        XCTAssertEqual(try joined("", skeleton: 0..<0, []), "")
    }

    func testAPlaceOutsideThePartBuiltSoFarIsDamaged() {
        for place in [3, 4, 1000, -1] {
            XCTAssertThrowsError(try joined("AAxx", skeleton: 0..<2, [(place, 2..<4)]), "place \(place)") {
                guard case .damaged? = $0 as? MOBIError else { return XCTFail("\($0)") }
            }
        }
        // The same place is fine once an earlier fragment has made the part longer.
        XCTAssertEqual(try joined("AAxxyy", skeleton: 0..<2, [(2, 2..<4), (4, 4..<6)]), "AAxxyy")
    }

    // MARK: - The anchors

    func testAnAnchorIsWrittenBeforeTheByteItNamesWhateverPieceHoldsIt() throws {
        let anchors = [
            KF8Layout.Anchor(position: 2, id: "filepos-2"),     // inside the skeleton's first piece
            KF8Layout.Anchor(position: 8, id: "filepos-8"),     // the first byte of the first fragment
            KF8Layout.Anchor(position: 11, id: "filepos-11"),   // inside the second fragment
        ]
        XCTAssertEqual(
            try joined("AAAABBBBxxyyy", skeleton: 0..<8, [(4, 8..<10), (6, 10..<13)], anchors: anchors),
            "AA<a id=\"filepos-2\"></a>AA<a id=\"filepos-8\"></a>xxy<a id=\"filepos-11\"></a>yyBBBB")
    }

    // MARK: - The cost

    /// The time `work` takes, the least of three runs.
    private func seconds(_ work: () throws -> Void) rethrows -> TimeInterval {
        var least = TimeInterval.infinity
        for _ in 0..<3 {
            let started = Date()
            try work()
            least = min(least, Date().timeIntervalSince(started))
        }
        return least
    }

    func testFragmentsThatGoInOrderCostOneStepEachAndGrowInStep() throws {
        /// A part of `count` fragments of one byte each, the skeleton "<>" and each fragment going in the middle after the last.
        func make(_ count: Int) -> ([UInt8], KF8Layout) {
            let text = [UInt8](repeating: 0x3C, count: 2) + [UInt8](repeating: 0x61, count: count)
            let fragments = (0..<count).map { (insert: 1 + $0, range: (2 + $0)..<(3 + $0)) }
            return (text, KF8Layout(parts: [part(skeleton: 0..<2, fragments)]))
        }
        let (smallText, small) = make(5_000)
        let (largeText, large) = make(40_000)
        var smallResult: [UInt8] = []
        var largeResult: [UInt8] = []
        let smallTime = try seconds { smallResult = try small.markup(of: small.parts[0], in: smallText, anchors: []) }
        let largeTime = try seconds { largeResult = try large.markup(of: large.parts[0], in: largeText, anchors: []) }
        XCTAssertEqual(smallResult.count, 5_002)
        XCTAssertEqual(largeResult.count, 40_002)
        XCTAssertEqual(largeResult.prefix(3), [0x3C, 0x61, 0x61])
        // Eight times the fragments: about eight times the time, nothing like sixty-four.
        XCTAssertLessThan(largeTime, max(smallTime * 24, 0.05), "5,000 took \(smallTime) s and 40,000 took \(largeTime) s")
        XCTAssertLessThan(largeTime, 1)
    }

    func testFragmentsThatAllGoToTheFrontAreRefusedBeforeTheyCostTheSquare() {
        // 60,000 fragments that each go to the front of the part built so far.
        let count = 60_000
        let text = [UInt8](repeating: 0x61, count: count + 1)
        let fragments = (0..<count).map { (insert: 0, range: (1 + $0)..<(2 + $0)) }
        let layout = KF8Layout(parts: [part(skeleton: 0..<1, fragments)])
        let started = Date()
        XCTAssertThrowsError(try layout.markup(of: layout.parts[0], in: text, anchors: [])) {
            guard case .damaged? = $0 as? MOBIError else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAFewFragmentsOutOfOrderAreFine() throws {
        // A hundred fragments, each going to the front: a book may do a few odd things.
        let count = 100
        let text = [UInt8](repeating: 0x61, count: count + 1)
        let fragments = (0..<count).map { (insert: 0, range: (1 + $0)..<(2 + $0)) }
        let layout = KF8Layout(parts: [part(skeleton: 0..<1, fragments)])
        XCTAssertEqual(try layout.markup(of: layout.parts[0], in: text, anchors: []).count, count + 1)
    }
}
