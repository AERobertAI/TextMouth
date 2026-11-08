import XCTest
@testable import TextMouth

/// `PhoneNavigationUnits`: what each kind of book offers, the unit in force,
/// and adjusting through the units, by the spec's "Navigation unit".
@MainActor
final class PhoneNavigationUnitsTests: XCTestCase {
    /// A text book with pages offers every unit, in the Mac's order.
    func testATextBookWithPagesOffersEveryUnitInTheMacsOrder() {
        XCTAssertEqual(
            PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: true),
            SkipUnit.allCases
        )
    }

    /// A text book without pages leaves out Page alone.
    func testATextBookWithoutPagesLeavesOutPage() {
        XCTAssertEqual(
            PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: false),
            SkipUnit.allCases.filter { $0 != .page }
        )
    }

    /// An audiobook has no text to stop at, so Sentence and Paragraph aren't
    /// offered; nor Page without pages.
    func testAnAudiobookLeavesOutSentenceParagraphAndPageWithoutPages() {
        XCTAssertEqual(
            PhoneNavigationUnits.offered(isAudioBook: true, hasSeveralPages: false),
            [.seconds10, .seconds15, .seconds30, .seconds60, .heading, .subheading, .bookmark]
        )
        XCTAssertEqual(
            PhoneNavigationUnits.offered(isAudioBook: true, hasSeveralPages: true),
            [.seconds10, .seconds15, .seconds30, .seconds60, .page, .heading, .subheading, .bookmark]
        )
    }

    /// The book's own unit is in force when the book offers it
    /// (`PhoneDefaults.navigationUnit`, which the reader's model asks).
    func testTheBooksOwnUnitIsInForce() {
        let offered = PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: true)
        XCTAssertEqual(unitInForce(own: "Bookmark", isAudio: false, offered: offered), .bookmark)
    }

    /// With no unit of its own, or one naming no unit, the kind's default is
    /// in force: Settings' choice, else Sentence for a text book.
    func testWithoutAUnitOfItsOwnTheKindsDefaultIsInForce() {
        let offered = PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: false)
        XCTAssertEqual(unitInForce(own: nil, isAudio: false, offered: offered), .sentence)
        XCTAssertEqual(unitInForce(own: "Chapter", isAudio: false, offered: offered, textDefault: .heading), .heading)
    }

    /// A saved unit the book doesn't offer, such as an audiobook's Sentence
    /// or Page in a book without pages, falls to the kind's default.
    func testAUnitTheBookDoesntOfferFallsToTheDefault() {
        let audio = PhoneNavigationUnits.offered(isAudioBook: true, hasSeveralPages: false)
        XCTAssertEqual(unitInForce(own: "Sentence", isAudio: true, offered: audio, audioDefault: .seconds30), .seconds30)
        let text = PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: false)
        XCTAssertEqual(unitInForce(own: "Page", isAudio: false, offered: text), .sentence)
    }

    /// A default the book doesn't offer either, such as Page for an
    /// audiobook without pages, falls to the spec's 15 seconds.
    func testADefaultTheBookDoesntOfferFallsToTheSpecsFallback() {
        let audio = PhoneNavigationUnits.offered(isAudioBook: true, hasSeveralPages: false)
        XCTAssertEqual(unitInForce(own: nil, isAudio: true, offered: audio, audioDefault: .page), .seconds15)
    }

    /// Adjusting up gives the next offered unit, and wraps from the last to
    /// the first; adjusting down goes back, and wraps the other way.
    func testAdjustingStepsThroughTheOfferedUnitsAndWraps() {
        let offered = PhoneNavigationUnits.offered(isAudioBook: false, hasSeveralPages: false)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .sentence, up: true, in: offered), .paragraph)
        // Page isn't offered, so Paragraph steps to Heading.
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .paragraph, up: true, in: offered), .heading)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .bookmark, up: true, in: offered), .seconds10)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .seconds10, up: false, in: offered), .bookmark)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .heading, up: false, in: offered), .paragraph)
    }

    /// A unit not offered steps to the offered unit beside where it sits in
    /// the Mac's order, so a step never lands on a unit that does nothing.
    func testAUnitNotOfferedStepsToItsOfferedNeighbor() {
        let audio = PhoneNavigationUnits.offered(isAudioBook: true, hasSeveralPages: false)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .sentence, up: true, in: audio), .heading)
        XCTAssertEqual(PhoneNavigationUnits.unit(after: .paragraph, up: false, in: audio), .seconds60)
    }

    /// Every step from every unit, both ways, lands on an offered unit, and
    /// a full round up visits each offered unit once.
    func testEveryStepLandsOnAnOfferedUnit() {
        for isAudioBook in [false, true] {
            for hasPages in [false, true] {
                let offered = PhoneNavigationUnits.offered(isAudioBook: isAudioBook, hasSeveralPages: hasPages)
                for unit in SkipUnit.allCases {
                    for up in [false, true] {
                        XCTAssertTrue(offered.contains(PhoneNavigationUnits.unit(after: unit, up: up, in: offered)))
                    }
                }
                // No unit offered fails here, never traps below.
                guard let first = offered.first else {
                    XCTFail("No unit offered, audio \(isAudioBook), pages \(hasPages)")
                    continue
                }
                var visited: [SkipUnit] = []
                var unit = first
                for _ in offered {
                    visited.append(unit)
                    unit = PhoneNavigationUnits.unit(after: unit, up: true, in: offered)
                }
                XCTAssertEqual(visited, offered)
                XCTAssertEqual(unit, first)
            }
        }
    }

    /// The name in lower case, for hints and the words of a move that went
    /// nowhere.
    func testTheLowerCaseName() {
        XCTAssertEqual(PhoneNavigationUnits.lowercasedName(of: .sentence), "sentence")
        XCTAssertEqual(PhoneNavigationUnits.lowercasedName(of: .seconds10), "10 seconds")
        XCTAssertEqual(PhoneNavigationUnits.lowercasedName(of: .subheading), "subheading")
    }

    // MARK: - Helpers

    /// The unit in force for a book whose own unit is `own`, with Settings'
    /// defaults as given, kept in preferences of the test's own.
    @MainActor
    private func unitInForce(
        own: String?,
        isAudio: Bool,
        offered: [SkipUnit],
        textDefault: SkipUnit? = nil,
        audioDefault: SkipUnit? = nil
    ) -> SkipUnit {
        let preferences = makeSandboxedPreferences("PhoneNavigationUnits")
        if let textDefault { PhoneDefaults.setTextNavigationUnit(textDefault, in: preferences) }
        if let audioDefault { PhoneDefaults.setAudioNavigationUnit(audioDefault, in: preferences) }
        return PhoneDefaults.navigationUnit(ownRawValue: own, isAudio: isAudio, offered: offered, in: preferences)
    }
}
