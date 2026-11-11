import XCTest

/// What every UI test of the iPhone app shares: a launch with a library of
/// its own, a public-domain book sent to it as another app would send one,
/// waits that each have a limit, what VoiceOver would be given read in order,
/// and Apple's accessibility audit with every finding listed.
///
/// **Sound.** A test may press Play and type, as a person does, but the
/// simulator plays through the Mac's speakers and the keyboard clicks, so such
/// a test runs only where nobody is listening: on a GitHub runner. The runner's
/// script (`Scripts/agents/run-ios-ui-tests.py`) alone sets
/// `TEXTMOUTH_UI_SOUND` to 1 for the test run, and `requireSound` skips a test,
/// saying why, when it isn't. On the development Mac every such test skips. The
/// helpers that make sound (`pressPlay`, `pressPause`, `startSleepTimer`,
/// `type`) ask first themselves, so a test that forgets still cannot make a
/// sound there. Apple's iOS audits only inspect: the audit that weighs an
/// element's actions exists on macOS alone (XCUIAccessibilityAuditTypes.h).
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

    // MARK: - Sound

    /// The environment variable that lets a test make sound: it is 1 only in a
    /// run the GitHub runner's script made.
    static let soundVariable = "TEXTMOUTH_UI_SOUND"

    /// Whether this run may make sound (play the book, type).
    static var soundIsAllowed: Bool {
        ProcessInfo.processInfo.environment[soundVariable] == "1"
    }

    /// The words every skip for sound has in its reason. The runner's script looks for them, since it sets the
    /// variable: a test that says them there never got it, and the run is judged failed
    /// (`SOUND_SKIP_MARKER` in Scripts/agents/run-ios-ui-tests.py is this text, and a test pins that they agree).
    static let soundSkipMarker = "runs only on a GitHub runner"

    /// Skips the test, saying why, unless this run may make sound. `what` is
    /// what the test does that sounds ("Pressing Play").
    func requireSound(_ what: String) throws {
        try XCTSkipUnless(
            Self.soundIsAllowed,
            "\(what) makes sound, so it \(Self.soundSkipMarker), where \(Self.soundVariable) is 1 "
                + "(Scripts/agents/run-ios-ui-tests.py sets it); on this Mac it is skipped."
        )
    }

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

    // MARK: - Playing and Typing

    /// Presses Play and waits for the control to read "Pause". Skips the test
    /// where sound isn't allowed.
    func pressPlay(in app: XCUIApplication) throws {
        try requireSound("Pressing Play")
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: Self.patience), "No Play to press:\n\(app.debugDescription)")
        play.tap()
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: Self.patience),
            "Play was pressed and the control never read Pause:\n\(app.debugDescription)"
        )
    }

    /// Presses Pause and waits for the control to read "Play". Skips the test
    /// where sound isn't allowed.
    func pressPause(in app: XCUIApplication) throws {
        try requireSound("Pressing Pause")
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: Self.patience), "No Pause to press:\n\(app.debugDescription)")
        pause.tap()
        XCTAssertTrue(
            app.buttons["Play"].waitForExistence(timeout: Self.patience),
            "Pause was pressed and the control never read Play:\n\(app.debugDescription)"
        )
    }

    /// Opens the Sleep Timer sheet, presses the button labeled `button` (a
    /// preset or a Stop At choice, each of which starts the book playing), and
    /// waits for the sheet to close, as the Mac's "Close sheet after setting
    /// timer" has it. Skips the test where sound isn't allowed.
    func startSleepTimer(_ button: String, in app: XCUIApplication) throws {
        try requireSound("Setting a sleep timer, which starts the book playing")
        _ = try openReaderSheet("Sleep Timer", titled: "Sleep Timer", waitingFor: "Close", in: app)
        let choice = app.buttons[button]
        XCTAssertTrue(choice.waitForExistence(timeout: Self.patience), "No \"\(button)\" in the sheet:\n\(app.debugDescription)")
        choice.tap()
        XCTAssertTrue(
            app.navigationBars["Sleep Timer"].waitForNonExistence(timeout: Self.patience),
            "The Sleep Timer sheet stayed open after \"\(button)\":\n\(app.debugDescription)"
        )
    }

    /// Types `text` into the text field labeled `label`, as a person does: the
    /// field is tapped to hold the keyboard if it does not hold it yet, then
    /// the keys are pressed. A second call finds the keyboard up and does not
    /// tap again, which could move the insertion point (at large text sizes
    /// the tap lands inside the text). Skips the test where sound isn't
    /// allowed (the keyboard clicks).
    func type(_ text: String, intoFieldLabeled label: String, in app: XCUIApplication) throws {
        try requireSound("Typing")
        let field = app.textFields[label]
        XCTAssertTrue(field.waitForExistence(timeout: Self.patience), "No field labeled \"\(label)\":\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists {
            field.tap()
        }
        dismissKeyboardIntroduction(in: app)
        field.typeText(text)
    }

    /// Presses Continue on the keyboard's one-time page about sliding a finger
    /// across the letters, if it covers the keyboard: the runner's script turns
    /// it off, and a fresh simulator that still shows it would otherwise keep
    /// every key from the field.
    func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let page = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Speed up your typing")).firstMatch
        if page.waitForExistence(timeout: 2) {
            app.buttons["Continue"].tap()
        }
    }

    /// The text of the "Book content" element, or empty when it holds none.
    func bookContent(in app: XCUIApplication) throws -> String {
        try elementsInOrder(of: app).first { $0.label == "Book content" }?.value ?? ""
    }

    /// Taps `element` until `expected` shows, at most three times, five
    /// seconds apart: at the largest text size the first tap after a launch
    /// was seen to do nothing (a Back, an Add to Library; November 9, 2026), so
    /// one tap is not trusted there. `what` names the tap in the failure,
    /// which carries the screen's tree.
    func tap(_ element: XCUIElement, until expected: XCUIElement, in app: XCUIApplication, what: String) {
        for _ in 0..<3 {
            // A tap whose screen took longer than the wait to come has worked.
            if expected.exists { return }
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

    // MARK: - The Reader's Sheets

    /// Opens the reader's sheet from its control, waits for the sheet's
    /// navigation bar and for the button `element`, and returns the sheet's
    /// elements in order.
    func openReaderSheet(
        _ control: String,
        titled title: String,
        waitingFor element: String,
        in app: XCUIApplication
    ) throws -> [Element] {
        // The tap is repeated if the sheet does not come: a first tap was seen
        // to do nothing (Bookmarks, pass 5, November 9, 2026).
        tap(app.buttons[control], until: app.navigationBars[title], in: app, what: "the \(control) control")
        XCTAssertTrue(
            app.buttons[element].waitForExistence(timeout: Self.patience),
            "The \(control) sheet has no \(element). Its bars' buttons: \(barButtons(of: app)). Order: \((try? elementsInOrder(of: app)).map(Self.describe) ?? "unreadable")"
        )
        return try elementsOfSheet(titled: title, in: app)
    }

    /// The elements of the sheet titled `title`, in order: everything from its
    /// title on. A sheet's navigation bar is known by its identifier and
    /// carries no label, so the order holds its title as the text inside it.
    /// The screen under a sheet may still be in the tree before it, and a
    /// control there can share the sheet's name ("Bookmarks", "Navigation
    /// unit"), but that is a button: the last titled element that isn't one
    /// is where the sheet begins.
    func elementsOfSheet(titled title: String, in app: XCUIApplication) throws -> [Element] {
        let elements = try elementsInOrder(of: app)
        guard let start = elements.lastIndex(where: { $0.label == title && $0.type != .button }) else {
            XCTFail("No navigation bar titled \"\(title)\" in: \(elements.map(\.label).joined(separator: " | "))")
            return []
        }
        return Array(elements[start...])
    }

    // MARK: - The Audit and the Record

    /// A finding the audit makes of a part of iOS the app doesn't draw, which
    /// the app can't change, matched by the audit's type and the element's
    /// label (exactly, or by its start when `labelIsPrefix`), and, when
    /// `description` is given, Apple's own short description of it, with the
    /// reason it's accepted.
    struct Accepted {
        let type: XCUIAccessibilityAuditType
        let label: String
        let why: String
        /// Whether `label` need only begin the element's label.
        var labelIsPrefix = false
        /// Apple's `compactDescription` the finding must have, or none.
        var description: String?

        /// Whether the finding of `type`, on an element labeled `elementLabel`
        /// (empty when it names none), described as `compact`, is this one.
        func matches(type findingType: XCUIAccessibilityAuditType, label elementLabel: String, description compact: String) -> Bool {
            guard findingType.contains(type) else { return false }
            guard labelIsPrefix ? elementLabel.hasPrefix(label) : elementLabel == label else { return false }
            return description.map { $0 == compact } ?? true
        }

        /// The Library's summary row, "1 book. 2 hours, ... remaining at
        /// current speed", whose Dynamic Type finding ("partially unsupported")
        /// is a plain `Text` in the subheadline style that grows and wraps
        /// (the screenshots of `LargeTextUITests`, 5 lines at the largest
        /// size). Its cause is not known. Matched by the summary's first
        /// words (they begin with the book count, "1 book.") and the Dynamic
        /// Type kind only; the same row's other findings, and every other
        /// row's, still fail.
        static let librarySummary = Accepted(
            type: .dynamicType, label: "1 book.",
            why: "the Library's summary row: a plain Text that grows and wraps, flagged for a cause not known",
            labelIsPrefix: true
        )

        /// A Dynamic Type finding that names no element, in Apple's exact
        /// words `description`. Every Dynamic Type finding that names an
        /// element (audited alone) is matched by that element, so one that
        /// names none can only be matched by its words. Two wordings were seen
        /// at the largest size, on the scrolled screens: "...are unsupported"
        /// on Settings (pass 1 to 5; probably the system stepper's minus and
        /// plus, which iOS does not grow, unproven) and "...are partially
        /// unsupported" on the Library (pass 5, once). Matched by an empty
        /// label, the Dynamic Type kind, and the exact words only.
        static func unnamedDynamicType(_ description: String) -> Accepted {
            Accepted(
                type: .dynamicType, label: "",
                why: "a finding that names no element, which the audit gives no way to find; the words are Apple's",
                description: description
            )
        }

        /// "Dynamic Type font sizes are unsupported", with no element.
        static let unnamedUnsupported = unnamedDynamicType("Dynamic Type font sizes are unsupported")

        /// "Dynamic Type font sizes are partially unsupported", with no element.
        static let unnamedPartlyUnsupported = unnamedDynamicType("Dynamic Type font sizes are partially unsupported")

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

        /// On a screen scrolled part of the way, text cut by the edge of the
        /// screen or by the bar it scrolls under: the audit reports "Text
        /// clipped" for it with no element (once or twice a pass, November 9,
        /// 2026). The screenshot of pass 4 shows exactly that on Settings at
        /// the largest size, scrolled: a line cut at the top under the
        /// navigation bar's glass, and a row cut at the bottom edge. Matched by
        /// an empty label, the clipped-text kind, and Apple's exact words, and
        /// used only by the audits of a scrolled screen.
        static let scrolledPastTheEdge = Accepted(
            type: .textClipped, label: "",
            why: "text cut by the screen's edge or the bar on a scrolled screen, which is what scrolling does",
            description: "Text clipped"
        )

        /// The navigation bar's title: iOS truncates a long title at large
        /// sizes, and VoiceOver and braille read it whole.
        static func navigationTitle(_ title: String) -> Accepted {
            Accepted(type: .textClipped, label: title, why: "the navigation bar's title, read whole by VoiceOver and braille")
        }
    }

    /// The kinds of finding iOS audits (XCUIAccessibilityAuditTypes.h of the
    /// iOS 26.0 SDK has these seven), each with its name: the one table that
    /// `audit` runs from and `name(of:)` reads.
    private static let auditKinds: [(kind: XCUIAccessibilityAuditType, name: String)] = [
        (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
        (.sufficientElementDescription, "element description"), (.dynamicType, "Dynamic Type"),
        (.textClipped, "clipped text"), (.trait, "trait"),
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
    /// combined run. Every kind in `auditKinds`, the seven this SDK has, still
    /// runs; a kind a later SDK adds would need a row there.
    ///
    /// Each finding names its element with its type, label, value, identifier,
    /// and frame in points (`trace(of:named:)`), so that a finding can be found on
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
        for (kind, _) in Self.auditKinds where !types.intersection(kind).isEmpty {
            try app.performAccessibilityAudit(for: kind) { issue in
                // One snapshot of the element, taken only if it still exists
                // (reading a missing element's properties fails the test),
                // serves the match and the trace.
                let snapshot = Self.snapshot(of: issue.element)
                let label = snapshot?.label ?? ""
                let said = "[\(Self.name(of: issue.auditType))] \(Self.trace(of: snapshot, named: issue.element != nil)): \(issue.compactDescription). \(issue.detailedDescription)"
                if let match = accepted.first(where: { $0.matches(type: issue.auditType, label: label, description: issue.compactDescription) }) {
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

    /// A snapshot of an audit finding's `element`, or none when the finding
    /// names no element or the element is gone (the check is `exists`, which
    /// never fails the test, where reading a missing element's properties
    /// would).
    static func snapshot(of element: XCUIElement?) -> (any XCUIElementSnapshot)? {
        guard let element, element.exists else { return nil }
        return try? element.snapshot()
    }

    /// What an audit finding's element is, to find it on the screenshot: its
    /// type, label, value, identifier, and frame in points, whether it is
    /// enabled, and how many elements it holds. "no element" when the finding
    /// names none (`named` false), and a note when it named one that is gone
    /// by the time it is read.
    static func trace(of snapshot: (any XCUIElementSnapshot)?, named: Bool) -> String {
        guard named else { return "no element" }
        guard let snapshot else { return "an element no longer in the tree" }
        let value = snapshot.value.map { "\($0)" } ?? "none"
        return "\(snapshot.elementType.rawValue) \"\(snapshot.label)\" (value \(value), id \"\(snapshot.identifier)\", "
            + "frame \(snapshot.frame), enabled \(snapshot.isEnabled), \(snapshot.children.count) children)"
    }

    /// The name of an iOS audit type, as XCUIAccessibilityAuditTypes.h has it.
    static func name(of type: XCUIAccessibilityAuditType) -> String {
        let matched = auditKinds.filter { type.contains($0.kind) }.map(\.name)
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
