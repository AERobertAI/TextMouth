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

    /// Launches the app with an empty library of its own (TEXTMOUTH_UI_TEST),
    /// sending it the book when `sendingTheBook`, as another app would at a
    /// cold launch (TEXTMOUTH_OPEN_AT_LAUNCH). With no book playing, the app
    /// imports the book and opens it, and Play waits unpressed.
    func launch(sendingTheBook: Bool) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TEXTMOUTH_UI_TEST"] = "1"
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
    func launchIntoTheReader() throws -> XCUIApplication {
        let app = try launch(sendingTheBook: true)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: Self.patience), "The reader never opened:\n\(app.debugDescription)")
        // Not the test case's own expectation, so nothing is left unwaited.
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == nil OR value != %@", "Loading"), object: play
        )
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: Self.patience), .completed, "The book never finished loading")
        return app
    }

    // MARK: - What VoiceOver Is Given, in Order

    /// One element of the screen as XCUITest reads it.
    struct Element {
        let type: XCUIElement.ElementType
        let label: String
        let value: String?
        let frame: CGRect
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
                found.append(Element(type: snapshot.elementType, label: snapshot.label, value: value, frame: snapshot.frame))
            }
            // Pushed last child first, so the first child is read next.
            stack.append(contentsOf: snapshot.children.reversed())
        }
        return found
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
                let order = elements.map(\.label).joined(separator: " | ")
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

        /// A button in the bar at the bottom: iOS doesn't grow bar items with
        /// Dynamic Type, and shows them in the Large Content Viewer instead.
        static func barItem(_ label: String) -> Accepted {
            Accepted(type: .dynamicType, label: label, why: "a bar item, which iOS shows in the Large Content Viewer")
        }

        /// The navigation bar's title: iOS truncates a long title at large
        /// sizes, and VoiceOver and braille read it whole.
        static func navigationTitle(_ title: String) -> Accepted {
            Accepted(type: .textClipped, label: title, why: "the navigation bar's title, read whole by VoiceOver and braille")
        }
    }

    /// Runs Apple's accessibility audit on the screen showing, every iOS type
    /// of it, and fails once with every finding not `accepted` listed, each
    /// with its type, its element, and Apple's words, so one run shows them
    /// all. The accepted ones are kept with the results, with their reasons.
    func audit(
        _ app: XCUIApplication,
        screen: String,
        accepting accepted: [Accepted] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var findings: [String] = []
        var acceptedFindings: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let label = issue.element?.label ?? ""
            let element = issue.element.map { "\($0.elementType.rawValue) \"\(label)\"" } ?? "no element"
            let said = "[\(Self.name(of: issue.auditType))] \(element): \(issue.compactDescription). \(issue.detailedDescription)"
            if let match = accepted.first(where: { issue.auditType.contains($0.type) && label == $0.label }) {
                acceptedFindings.append("\(said) Accepted: \(match.why).")
            } else {
                findings.append(said)
            }
            // Handled here, listed below.
            return true
        }
        keepScreenshot(of: app, named: "\(screen) audited")
        if !acceptedFindings.isEmpty {
            let note = XCTAttachment(string: acceptedFindings.joined(separator: "\n"))
            note.name = "\(screen): findings accepted"
            note.lifetime = .keepAlways
            add(note)
        }
        XCTAssertTrue(
            findings.isEmpty,
            "The \(screen)'s audit found \(findings.count):\n" + findings.joined(separator: "\n"),
            file: file, line: line
        )
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
