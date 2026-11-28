import SwiftUI
import UIKit
import XCTest
@testable import TextMouth

/// `PhoneValueRow`, the row that shows a name and its value: beside each other
/// at the ordinary text sizes, and, at the five accessibility sizes, the value
/// under the name, so that each takes the whole width and a name never breaks
/// in the middle of a word beside its value (the largest size did that to
/// "Fade out duration" in the simulator's screenshot).
///
/// The row is measured, not drawn on a screen: a hosting controller is asked
/// how tall the row is at a width, with the text size set in its environment,
/// and that height is compared with the heights of the name alone and of the
/// value alone at the same width. Stacked, the row is the two heights and the
/// gap between them; side by side, it is the taller of the two. Nothing here
/// plays, types, or opens a screen.
@MainActor
final class PhoneValueRowTests: XCTestCase {

    // MARK: - Fixtures

    /// A narrow phone's row, in points: a Form's rows are inset from the
    /// screen, so the width a row has is less than the screen's.
    private let width: CGFloat = 300
    /// The gap `PhoneValueRow` puts between a stacked name and value.
    private let gap: CGFloat = 4

    /// The five accessibility sizes, where the row stacks.
    private var accessibilitySizes: [DynamicTypeSize] {
        DynamicTypeSize.allCases.filter(\.isAccessibilitySize)
    }

    /// The seven sizes below them, where the row stays side by side.
    private var ordinarySizes: [DynamicTypeSize] {
        DynamicTypeSize.allCases.filter { !$0.isAccessibilitySize }
    }

    /// How tall `view` is at `size`, in a space `width` wide and as tall as it
    /// likes.
    private func height(of view: some View, at size: DynamicTypeSize) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// How tall the row of `name` and `value` is at `size`, and how tall the
    /// two would be one above the other (each alone at the whole width, and
    /// the gap): what the row would measure if it stacked.
    private func measure(name: String, value: String, at size: DynamicTypeSize) -> (row: CGFloat, stacked: CGFloat) {
        let nameAlone = height(of: Text(name).frame(maxWidth: .infinity, alignment: .leading), at: size)
        let valueAlone = height(of: Text(value).frame(maxWidth: .infinity, alignment: .leading), at: size)
        let row = height(of: PhoneValueRow(name: name, value: value), at: size)
        return (row, nameAlone + gap + valueAlone)
    }

    // MARK: - The Accessibility Sizes

    /// There are five accessibility sizes and seven ordinary ones, and the
    /// tests below cover each: if SwiftUI gained or lost a size, the count
    /// says so.
    func testThereAreFiveAccessibilitySizesAndSevenOrdinaryOnes() {
        XCTAssertEqual(accessibilitySizes.count, 5, "\(accessibilitySizes)")
        XCTAssertEqual(ordinarySizes.count, 7, "\(ordinarySizes)")
    }

    /// At every accessibility size the row is the name's height, the gap, and
    /// the value's: one above the other, each at the whole width. The name is
    /// the one that was broken in the middle of a word.
    func testAtEveryAccessibilitySizeTheValueGoesUnderTheName() {
        var misses: [String] = []
        for size in accessibilitySizes {
            let measured = measure(name: "Fade out duration", value: "5 seconds", at: size)
            if abs(measured.row - measured.stacked) > 1.5 {
                misses.append("\(size): the row is \(measured.row) tall; stacked it would be \(measured.stacked)")
            }
        }
        XCTAssertEqual(misses, [], "The name and value do not stack at: \(misses)")
    }

    // MARK: - The Ordinary Sizes

    /// At every ordinary size the name and value share a line, so the row is
    /// shorter than the two stacked. A short pair, so that they fit one line
    /// at the largest ordinary size.
    func testAtEveryOrdinarySizeTheValueStaysBesideTheName() {
        var misses: [String] = []
        for size in ordinarySizes {
            let measured = measure(name: "Pitch", value: "Normal", at: size)
            if measured.row > measured.stacked - 1.5 {
                misses.append("\(size): the row is \(measured.row) tall, as tall as the \(measured.stacked) of a stacked pair")
            }
        }
        XCTAssertEqual(misses, [], "The value is under the name at an ordinary size: \(misses)")
    }
}
