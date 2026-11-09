import XCTest

/// What every UI test of the iPhone app shares: a launch with a library of
/// its own, a public-domain book sent to it as another app would send one,
/// waits that each have a limit, what VoiceOver would be given read in order,
/// and Apple's accessibility audit with every finding listed.
///
/// Nothing here presses Play, or anything else that makes a sound, since the
/// simulator plays through the Mac's speakers, and no test types, since the
/// keyboard's clicks are sounds too. Apple's iOS audits only inspect: the
/// audit that weighs an element's actions exists on macOS alone
/// (XCUIAccessibilityAuditTypes.h).
@MainActor
class TextMouthUITestCase: XCTestCase {
    /// The longest any wait lasts: a small book's import and opening take a
    /// few seconds, and a first launch in a fresh simulator takes longer.
    static let patience: TimeInterval = 60

    /// The book every test sends: Alice's Adventures in Wonderland, Project
    /// Gutenberg #11, which the Mac's tests read too.
    static let bookTitle = "Alice's Adventures in Wonderland"
    /// Its author, as its row reads it.
    static let bookAuthor = "Lewis Carroll"

    // MARK: - Launching

    /// The largest text size iOS offers, Accessibility Extra Extra Extra Large.
    static let largestText = "UICTContentSizeCategoryAccessibilityXXXL"

    /// Launches the app with an empty library of its own (TEXTMOUTH_UI_TEST),
    /// sending it the book when `sendingTheBook`, as another app would at a
    /// cold launch (TEXTMOUTH_OPEN_AT_LAUNCH). With no book playing, the app
    /// imports the book and opens it, and Play waits unpressed.
    /// With `textSize`, the launch uses that content size category (as in
    /// `Self.largestText`), as the Larger Text setting would.
    func launch(sendingTheBook: Bool, textSize: String? = nil) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TEXTMOUTH_UI_TEST"] = "1"
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        if sendingTheBook {
            app.launchEnvironment["TEXTMOUTH_OPEN_AT_LAUNCH"] = try Self.bookPath()
        }
        app.launch()
        return app
    }

    /// The book's path in this test bundle, where project.yml copies it.
    static func bookPath() throws -> String {
        let bundle = Bundle(for: TextMouthUITestCase.self)
        return try XCTUnwrap(bundle.url(forResource: "alice", withExtension: "epub"), "alice.epub is not in the bundle").path
    }

    /// Launches with the book and waits for the reader it opens, with the
    /// book loaded: Play is there, and its value no longer says "Loading".
    func launchIntoTheReader(textSize: String? = nil) throws -> XCUIApplication {
        let app = try launch(sendingTheBook: true, textSize: textSize)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: Self.patience), "The reader never opened:\n\(app.debugDescription)")
        // Not the test case's own expectation, so nothing is left unwaited.
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == nil OR value != %@", "Loading"), object: play
        )
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: Self.patience), .completed, "The book never finished loading")
        return app
    }

    /// Taps `element` until `expected` shows, at most three times, five
    /// seconds apart: at the largest text size the first tap after a launch
    /// was seen to do nothing (a Back, an Add to Library; November 9, 2026), so
    /// one tap is not trusted there. `what` names the tap in the failure,
    /// which carries the screen's tree.
    func tap(_ element: XCUIElement, until expected: XCUIElement, in app: XCUIApplication, what: String) {
        for _ in 0..<3 {
            guard element.waitForExistence(timeout: Self.patience) else {
                XCTFail("No \(what) to tap:\n\(app.debugDescription)")
                return
            }
            element.tap()
            if expected.waitForExistence(timeout: 5) { return }
        }
        XCTFail("Tapping \(what) three times did not bring up what it should:\n\(app.debugDescription)")
    }

    // MARK: - What VoiceOver Is Given, in Order

    /// One element of the screen as XCUITest reads it.
    struct Element {
        let type: XCUIElement.ElementType
        let label: String
        let value: String?
        let frame: CGRect
        /// The accessibility identifier, which iOS sometimes gives a control
        /// that its label does not name (a toolbar button, for one).
        let identifier: String
    }

    /// Every element of `app` with a label, in the order of the accessibility
    /// tree, depth first: the order VoiceOver moves through with a flick,
    /// unless a container orders its own. Read from one snapshot, so the
    /// screen can't change halfway through. Walked with a stack of its own.
    func elementsInOrder(of app: XCUIApplication) throws -> [Element] {
        var found: [Element] = []
        var stack: [any XCUIElementSnapshot] = [try app.snapshot()]
        while let snapshot = stack.popLast() {
            if !snapshot.label.isEmpty {
                let value = snapshot.value.map { "\($0)" }
                found.append(Element(
                    type: snapshot.elementType, label: snapshot.label, value: value,
                    frame: snapshot.frame, identifier: snapshot.identifier
                ))
            }
            // Pushed last child first, so the first child is read next.
            stack.append(contentsOf: snapshot.children.reversed())
        }
        return found
    }

    /// The elements as one line: each one's label, with its identifier where
    /// that is not the label (a button iOS names by an identifier alone shows
    /// here), and "(button)" after a button.
    static func describe(_ elements: [Element]) -> String {
        elements.map { element in
            var text = element.label
            if !element.identifier.isEmpty, element.identifier != element.label { text += " [id \(element.identifier)]" }
            return element.type == .button ? "\(text) (button)" : text
        }.joined(separator: " | ")
    }

    /// The buttons of every navigation bar showing, by label and identifier:
    /// what to print when a button the test expects is missing.
    func barButtons(of app: XCUIApplication) -> String {
        app.navigationBars.buttons.allElementsBoundByIndex.map {
            "label \"\($0.label)\" id \"\($0.identifier)\""
        }.joined(separator: "; ")
    }

    /// Fails unless each of `expected` is the label of an element of
    /// `elements` (one ending in "…" only begins it), each after the last.
    func assertOrder(_ expected: [String], in elements: [Element], file: StaticString = #filePath, line: UInt = #line) {
        var from = elements.startIndex
        for label in expected {
            let matches: (Element) -> Bool = label.hasSuffix("…")
                ? { $0.label.hasPrefix(String(label.dropLast())) }
                : { $0.label == label }
            guard let index = elements[from...].firstIndex(where: matches) else {
                let order = Self.describe(elements)
                XCTFail("\"\(label)\" is not after \"\(expected.first ?? "")\"… in the order: \(order)", file: file, line: line)
                return
            }
            from = elements.index(after: index)
        }
    }

    // MARK: - The Audit and the Record

    /// A finding the audit makes of a part of iOS the app doesn't draw, which
    /// the app can't change, matched by the audit's type and the element's
    /// label, with the reason it's accepted.
    struct Accepted {
        let type: XCUIAccessibilityAuditType
        let label: String
        let why: String

        /// The system's search field: iOS clips its placeholder at the
        /// largest text sizes, and VoiceOver and braille read it whole.
        static let searchField = Accepted(
            type: .textClipped, label: "Search books",
            why: "the system's search field, read whole by VoiceOver and braille"
        )

        /// A button in a bar, at the bottom of the Library or at the top of a
        /// sheet (Cancel, Done, Close): iOS doesn't grow bar items with
        /// Dynamic Type, and shows them in the Large Content Viewer instead.
        static func barItem(_ label: String) -> Accepted {
            Accepted(type: .dynamicType, label: label, why: "a bar item, which iOS shows in the Large Content Viewer")
        }

        /// The first section header under a navigation bar, which the audit
        /// reports as failing contrast ("Contrast failed for
        /// SwiftUI.AccessibilityNode") on Settings ("Voice") and on Sleep Timer
        /// ("New Timer"). It is a false positive, proven on November 9, 2026
        /// from the screenshots kept with the results: each header's frame
        /// (16, 116 or 132, 370 by 40 points) holds black text, (0, 0, 0), on a
        /// background of (235 to 242, 235 to 242, 240 to 247), whose lowest
        /// contrast is about 17 to 1, and the phone draws every header in the
        /// primary label color (`PhoneTextColor`). Matched by the header's own
        /// words and the contrast kind only: any other contrast finding, on
        /// these screens or any other, still fails.
        static func firstHeader(_ title: String) -> Accepted {
            Accepted(
                type: .contrast, label: title,
                why: "the first section header under the bar: black text on a near-white background, measured from the screenshot, a false positive"
            )
        }

        /// The navigation bar's title: iOS truncates a long title at large
        /// sizes, and VoiceOver and braille read it whole.
        static func navigationTitle(_ title: String) -> Accepted {
            Accepted(type: .textClipped, label: title, why: "the navigation bar's title, read whole by VoiceOver and braille")
        }
    }

    /// The kinds of finding iOS audits, each of which `audit` runs alone.
    private static let auditKinds: [XCUIAccessibilityAuditType] = [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait,
    ]

    /// Runs Apple's accessibility audit on the screen showing, every iOS type
    /// of it (or `types`), and fails once with every finding not `accepted`
    /// listed, each with its type, its element, and Apple's words, so one run
    /// shows them all. The accepted ones are kept with the results, with their
    /// reasons. A finding of a kind in `informed` is kept with the results and
    /// does not fail the test: for a kind a test checks another way.
    ///
    /// **Each kind is audited alone**, one `performAccessibilityAudit` per
    /// kind, and not all together (November 9, 2026, iPhone 17, iOS 26.0).
    /// Audited together, a finding names no element ("no element"), so it can't
    /// be matched to an accepted one or found on the screen; audited alone, it
    /// names its element. And Go To's "Potentially inaccessible text" appeared
    /// in both of the runs that audited every kind together, and in none of
    /// five launches that audited that kind alone, so it is a product of the
    /// combined run. Nothing is skipped: every kind still runs.
    ///
    /// Each finding names its element with its type, label, value, identifier,
    /// and frame in points (`trace(of:)`), so that a finding can be found on
    /// the screenshot kept with the results. When any finding is not accepted,
    /// the screen's whole accessibility tree, every element with its frame, is
    /// kept too ("<screen>: accessibility tree").
    func audit(
        _ app: XCUIApplication,
        screen: String,
        types: XCUIAccessibilityAuditType = .all,
        informing informed: XCUIAccessibilityAuditType = [],
        accepting accepted: [Accepted] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var findings: [String] = []
        var acceptedFindings: [String] = []
        var informingFindings: [String] = []
        for kind in Self.auditKinds where !types.intersection(kind).isEmpty {
            try app.performAccessibilityAudit(for: kind) { issue in
                let label = issue.element?.label ?? ""
                let said = "[\(Self.name(of: issue.auditType))] \(Self.trace(of: issue.element)): \(issue.compactDescription). \(issue.detailedDescription)"
                if let match = accepted.first(where: { issue.auditType.contains($0.type) && label == $0.label }) {
                    acceptedFindings.append("\(said) Accepted: \(match.why).")
                } else if !informed.isDisjoint(with: issue.auditType) {
                    // Kept with the results, and not failed.
                    informingFindings.append(said)
                } else {
                    findings.append(said)
                }
                // Handled here, listed below.
                return true
            }
        }
        keepScreenshot(of: app, named: "\(screen) audited")
        if !findings.isEmpty || !informingFindings.isEmpty {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(screen): accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        if !acceptedFindings.isEmpty {
            let note = XCTAttachment(string: acceptedFindings.joined(separator: "\n"))
            note.name = "\(screen): findings accepted"
            note.lifetime = .keepAlways
            add(note)
        }
        if !informingFindings.isEmpty {
            let note = XCTAttachment(string: informingFindings.joined(separator: "\n"))
            note.name = "\(screen): findings reported, not failed"
            note.lifetime = .keepAlways
            add(note)
        }
        XCTAssertTrue(
            findings.isEmpty,
            "The \(screen)'s audit found \(findings.count):\n" + findings.joined(separator: "\n"),
            file: file, line: line
        )
    }

    /// What an audit finding's element is, to find it on the screenshot: its
    /// type, label, value, identifier, and frame in points, whether it is
    /// enabled, and how many elements it holds. "no element" when the finding
    /// names none, and a note when the element is gone by the time it is read
    /// (reading a missing element's properties would fail the test).
    static func trace(of element: XCUIElement?) -> String {
        guard let element else { return "no element" }
        guard element.exists, let snapshot = try? element.snapshot() else { return "an element no longer in the tree" }
        let value = snapshot.value.map { "\($0)" } ?? "none"
        return "\(snapshot.elementType.rawValue) \"\(snapshot.label)\" (value \(value), id \"\(snapshot.identifier)\", "
            + "frame \(snapshot.frame), enabled \(snapshot.isEnabled), \(snapshot.children.count) children)"
    }

    /// The name of an iOS audit type, as XCUIAccessibilityAuditTypes.h has it.
    static func name(of type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "element description"), (.dynamicType, "Dynamic Type"),
            (.textClipped, "clipped text"), (.trait, "trait"),
        ]
        let matched = names.filter { type.contains($0.0) }.map(\.1)
        return matched.isEmpty ? "type \(type.rawValue)" : matched.joined(separator: ", ")
    }

    /// Keeps a screenshot of the screen with the test's results.
    func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
