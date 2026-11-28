import SwiftUI
import UIKit
import XCTest
@testable import TextMouth

/// The phone's wrapped words keep a little more height than they need (`phoneWholeWords`), measured, not drawn and audited.
///
/// The large-text audit read a frame that fits its words exactly as clipped text in some runs: the sleep timer label's
/// (249.33 points for words measuring 249.25) and the Braille caption's (the full suite of 0a5d1405b). The audit itself runs
/// on GitHub and sees the fit only some of the time, so this test measures the cause every time: the real caption and a
/// switch's label, hosted at the largest text size, must be at least one point taller than the same words measured at that
/// size and width. Without the line spacing a frame fits its words to within a tenth of a point, and this fails.
///
/// Nothing here plays, types, or speaks.
@MainActor
final class PhoneWholeWordsTests: XCTestCase {
    /// The width of the Settings column's text on the phone the audit runs on: its 402 points less the 16-point margins.
    private let width: CGFloat = 370

    /// The traits of the largest text size iOS offers.
    private let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

    /// The height `words` need in `style` at the largest size, wrapped at `width`, and how many lines that is.
    private func needed(_ words: String, style: UIFont.TextStyle) -> (height: CGFloat, lines: Int) {
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: largest)
        let height = (words as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return (height, Int((height / font.lineHeight).rounded()))
    }

    /// The height `view` takes at the largest size when it may be as tall as it needs, hosted in a window.
    private func height(of view: some View) throws -> CGFloat {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "The test host has no window scene"
        )
        let controller = UIHostingController(rootView: AnyView(view.dynamicTypeSize(.accessibility5).frame(width: width)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<3 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// The Braille section's captions, which are wrapped to several lines at the largest size, are at least a point taller than
    /// their words.
    func testTheBrailleCaptionsKeepAPointOverTheirWords() throws {
        for words in [
            PhoneSettingsWording.brailleCaption,
            BrailleSettingsWording.source(ofTable: "de-g1.ctb", isOffered: false, macLiblouisVersion: nil, writesOnly: true),
        ] {
            let measure = needed(words, style: .caption1)
            XCTAssertGreaterThan(measure.lines, 1, "the caption is not wrapped at the largest size, which this test needs")
            let frame = try height(of: PhoneReadableCaption(words))
            XCTAssertGreaterThanOrEqual(
                frame, measure.height + 1, "the caption's frame, \(frame), leaves less than a point over its words, \(measure.height)"
            )
        }
    }

    /// The modifier itself, which a switch's label takes: a label of several lines is a point taller than its words.
    func testASwitchLabelKeepsAPointOverItsWords() throws {
        let words = "Close sleep timer sheet after setting a timer"
        let measure = needed(words, style: .body)
        XCTAssertGreaterThan(measure.lines, 1)
        let frame = try height(of: Text(words).phoneWholeWords())
        XCTAssertGreaterThanOrEqual(frame, measure.height + 1, "the label's frame, \(frame), leaves less than a point over its words, \(measure.height)")
    }
}
