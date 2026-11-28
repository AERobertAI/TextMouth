import UIKit
import XCTest
@testable import TextMouth

/// `PhoneControlButton`, the UIKit button under each of the reader's controls,
/// in the iPhone app's own process. VoiceOver reads its getters, so each word
/// must be the moment's: asked of `describe` at every read, never pushed.
/// Adjusting and activating must act before VoiceOver reads again, so it reads
/// the new value and not the old (the spec, under "Why the reader's controls
/// are UIKit views"). Nothing here plays: the closures only count.
@MainActor
final class PhoneControlButtonTests: XCTestCase {

    // MARK: - Fixtures

    /// What a test's control says now; the button asks for it at each read.
    private var shown = PhoneControlDescription(label: "Play", traits: [.button])

    /// A button whose words are always `shown`'s.
    private func makeButton() -> PhoneControlButton {
        let button = PhoneControlButton()
        button.describe = { [weak self] in self?.shown }
        return button
    }

    // MARK: - The Words, When VoiceOver Asks

    /// Each getter reads `describe` when it is asked, with no refresh between:
    /// a change made since the last read is what VoiceOver reads next.
    func testEachWordIsTheMomentsWithNoRefresh() {
        let button = makeButton()
        shown = PhoneControlDescription(label: "Play", value: "Page 12", hint: "Moves back or forward by page.", traits: [.button])
        XCTAssertEqual(button.accessibilityLabel, "Play")
        XCTAssertEqual(button.accessibilityValue, "Page 12")
        XCTAssertEqual(button.accessibilityHint, "Moves back or forward by page.")

        shown = PhoneControlDescription(label: "Pause", hint: "Moves back or forward by sentence.", traits: [.button])
        XCTAssertEqual(button.accessibilityLabel, "Pause")
        XCTAssertNil(button.accessibilityValue, "An empty value is none, so VoiceOver says nothing for it")
        XCTAssertEqual(button.accessibilityHint, "Moves back or forward by sentence.")
    }

    /// Setting a word from outside changes nothing: the description is the
    /// one source, so no stale word can be pushed onto the control.
    func testSettingAWordFromOutsideChangesNothing() {
        let button = makeButton()
        button.accessibilityLabel = "Stale"
        button.accessibilityValue = "Stale"
        button.accessibilityHint = "Stale"
        button.accessibilityTraits = .header
        XCTAssertEqual(button.accessibilityLabel, "Play")
        XCTAssertNil(button.accessibilityValue)
        XCTAssertNil(button.accessibilityHint)
        XCTAssertEqual(button.accessibilityTraits, .button)
    }

    /// A value or hint of only spaces is none, as an empty one is.
    func testABlankValueOrHintIsNone() {
        let button = makeButton()
        shown = PhoneControlDescription(label: "Navigation unit", value: "  ", hint: "\n", traits: [.button, .adjustable])
        XCTAssertNil(button.accessibilityValue)
        XCTAssertNil(button.accessibilityHint)
    }

    /// The button is one element, whatever its title's label inside.
    func testTheButtonIsOneElement() {
        XCTAssertTrue(makeButton().isAccessibilityElement)
    }

    // MARK: - Traits

    /// Each of the phone's traits is UIKit's trait of the same name, and the
    /// set is exactly what the description says: Play while paused is a
    /// button that is adjustable and starts a media session.
    func testTheTraitsAreUIKitsOwn() {
        let button = makeButton()
        shown = PhoneControlDescription(label: "Play", traits: [.button, .adjustable, .startsMediaSession])
        XCTAssertEqual(button.accessibilityTraits, [.button, .adjustable, .startsMediaSession])

        shown = PhoneControlDescription(label: "Book content", traits: [.staticText])
        XCTAssertEqual(button.accessibilityTraits, .staticText)

        XCTAssertEqual(PhoneControlButton.traits(for: []), [])
        XCTAssertEqual(PhoneControlButton.traits(for: [.button, .staticText]), [.button, .staticText])
    }

    /// With nothing to describe, the control is a plain button, never
    /// something VoiceOver skips.
    func testWithNoDescriptionTheControlIsAButton() {
        let button = PhoneControlButton()
        XCTAssertNil(button.accessibilityLabel)
        XCTAssertEqual(button.accessibilityTraits, .button)
        XCTAssertNil(button.accessibilityCustomActions)
    }

    // MARK: - Activating and Adjusting

    /// Activating runs the control's action at once and says it was handled,
    /// so VoiceOver reads the new words next; with no action, UIKit's own
    /// handling is left to it.
    func testActivatingActsAtOnceAndSaysItWasHandled() {
        let button = makeButton()
        var presses = 0
        button.activate = { [weak self] in
            presses += 1
            self?.shown = PhoneControlDescription(label: "Pause", traits: [.button, .adjustable])
        }
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(button.accessibilityLabel, "Pause")
        XCTAssertEqual(button.configuration?.title, "Pause", "The visible title follows")

        button.activate = nil
        XCTAssertFalse(button.accessibilityActivate())
        XCTAssertEqual(presses, 1)
    }

    /// Adjusting up and down each run their move before returning, so the
    /// value VoiceOver reads after the flick is the move's.
    func testAdjustingMovesBeforeVoiceOverReadsTheValue() {
        let button = makeButton()
        var place = 3
        let read = { [weak self] in
            self?.shown = PhoneControlDescription(label: "Play", value: "Sentence \(place)", traits: [.button, .adjustable])
        }
        read()
        button.increment = { place += 1; read() }
        button.decrement = { place -= 1; read() }

        button.accessibilityIncrement()
        XCTAssertEqual(button.accessibilityValue, "Sentence 4")
        button.accessibilityDecrement()
        button.accessibilityDecrement()
        XCTAssertEqual(button.accessibilityValue, "Sentence 2")
    }

    /// Adjusting a control with no move does nothing, and doesn't trap.
    func testAdjustingWithNoMoveDoesNothing() {
        let button = makeButton()
        button.accessibilityIncrement()
        button.accessibilityDecrement()
        XCTAssertEqual(button.accessibilityLabel, "Play")
    }

    // MARK: - Actions

    /// Most controls have no actions, so VoiceOver doesn't say "Actions
    /// available"; one that has them offers each by its name, in order, and
    /// each runs its action.
    func testActionsAreOfferedOnlyWhereThereAreSome() throws {
        let button = makeButton()
        XCTAssertNil(button.accessibilityCustomActions)

        var performed: [PhoneControlAction] = []
        button.perform = { performed.append($0) }
        shown = PhoneControlDescription(
            label: "Where Am I?", traits: [.button], actions: [.whereAmIFullSummary, .copyReadingPosition]
        )
        let actions = try XCTUnwrap(button.accessibilityCustomActions)
        XCTAssertEqual(actions.map(\.name), [PhoneControlAction.whereAmIFullSummary.name, PhoneControlAction.copyReadingPosition.name])
        for action in actions {
            let handler = try XCTUnwrap(action.actionHandler, action.name)
            XCTAssertTrue(handler(action))
        }
        XCTAssertEqual(performed, [.whereAmIFullSummary, .copyReadingPosition])
    }

    // MARK: - The Visible Title

    /// The visible title is the label, or the label and value where the
    /// control shows its value, for a sighted helper; VoiceOver reads the
    /// getters either way.
    func testTheVisibleTitleShowsTheValueOnlyWhereAsked() {
        let button = makeButton()
        shown = PhoneControlDescription(label: "Speed", value: "1.5 times", traits: [.button, .adjustable])
        button.refreshTitle()
        XCTAssertEqual(button.configuration?.title, "Speed")
        button.showsValue = true
        button.refreshTitle()
        XCTAssertEqual(button.configuration?.title, "Speed: 1.5 times")
        shown = PhoneControlDescription(label: "Speed", traits: [.button, .adjustable])
        button.refreshTitle()
        XCTAssertEqual(button.configuration?.title, "Speed", "No colon for an empty value")
    }

    /// Apple's smallest target for a touch.
    func testTheSmallestHeightIsFortyFourPoints() {
        XCTAssertEqual(PhoneControlButton.minimumHeight, 44)
    }
}
