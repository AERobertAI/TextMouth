import AppKit
import XCTest
@testable import TextMouth

/// Keyboard- and VoiceOver-operable substitution editing and reordering
/// (TODO A03): one-step moves in the rule service, the words and commands
/// every rule row is built from, the moves the settings list makes and
/// announces, and the rows as AppKit renders them.
///
/// SwiftUI builds accessibility elements, and with them the labels, only
/// for a connected assistive app, so no hosted test can read a row's labels.
/// The wording tests pin those words; the rendered tests prove the controls
/// they belong to are drawn, dimmed correctly, and wired to their commands.
@MainActor
final class SubstitutionKeyboardAccessTests: XCTestCase {
    // MARK: - One-step moves

    /// One step reaches the neighbouring index. There is no step past either
    /// end of the list, and none from a position outside it.
    func testMoveDirectionFindsTheNeighbouringIndex() {
        let cases: [(index: Int, count: Int, up: Int?, down: Int?)] = [
            (index: 0, count: 3, up: nil, down: 1),
            (index: 1, count: 3, up: 0, down: 2),
            (index: 2, count: 3, up: 1, down: nil),
            (index: 0, count: 1, up: nil, down: nil),
            (index: 0, count: 0, up: nil, down: nil),
            (index: -1, count: 3, up: nil, down: nil),
            (index: 3, count: 3, up: nil, down: nil),
        ]
        for step in cases {
            let context = "from \(step.index) of \(step.count)"
            XCTAssertEqual(SubstitutionRuleMoveDirection.up.destination(from: step.index, count: step.count), step.up, "Up \(context)")
            XCTAssertEqual(SubstitutionRuleMoveDirection.down.destination(from: step.index, count: step.count), step.down, "Down \(context)")
        }
    }

    /// Moving one step swaps a rule with its neighbour, leaves every other
    /// rule where it was, and saves the new order in full.
    func testMoveRuleOneStepSwapsNeighboursAndSavesTheOrder() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 4)
        let service = TextSubstitutionService(rules: rules)

        XCTAssertEqual(service.moveRule(id: rules[2].id, direction: .up), 1)
        XCTAssertEqual(service.rules.map(\.name), ["A", "C", "B", "D"])
        XCTAssertEqual(try sandbox.savedRules(), service.rules)

        XCTAssertEqual(service.moveRule(id: rules[2].id, direction: .down), 2)
        XCTAssertEqual(service.rules, rules)
        XCTAssertEqual(try sandbox.savedRules(), rules)

        XCTAssertEqual(service.moveRule(id: rules[0].id, direction: .down), 1)
        XCTAssertEqual(service.rules.map(\.name), ["B", "A", "C", "D"])
        XCTAssertEqual(try sandbox.savedRules(), service.rules)
    }

    /// Nothing moves, and nothing is saved, for a step past either end of
    /// the list or for a rule the list does not hold.
    func testMoveRuleRefusesStepsPastTheEndsWithoutSaving() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 3)
        let service = TextSubstitutionService(rules: rules)
        try sandbox.removeSavedRules()

        XCTAssertNil(service.moveRule(id: rules[0].id, direction: .up))
        XCTAssertNil(service.moveRule(id: rules[2].id, direction: .down))
        XCTAssertNil(service.moveRule(id: UUID(), direction: .down))

        XCTAssertEqual(service.rules, rules)
        XCTAssertFalse(sandbox.hasSavedRules, "A refused move must not save")
    }

    // MARK: - Rule wording

    /// The checkbox names the rule it enables: by its name, or else by its
    /// pattern, or as "Untitled rule" when both are blank.
    func testEnableLabelNamesTheRule() {
        XCTAssertEqual(SubstitutionRule(name: "Mr.", pattern: "\\bMr\\.").enableLabel, "Enable Mr.")
        XCTAssertEqual(SubstitutionRule(name: "  Mr.  ", pattern: "\\bMr\\.").enableLabel, "Enable Mr.")
        XCTAssertEqual(SubstitutionRule(pattern: "colour").enableLabel, "Enable colour")
        XCTAssertEqual(SubstitutionRule(name: " ", pattern: " colour ").enableLabel, "Enable colour")
        XCTAssertEqual(SubstitutionRule(pattern: "   ").enableLabel, "Enable Untitled rule")
        XCTAssertEqual(SubstitutionRule(pattern: "").enableLabel, "Enable Untitled rule")
    }

    /// A rule's description gives its name, pattern, replacement, and
    /// options, and reads the same whether or not the rule is enabled.
    func testSummaryDescribesTheRuleWithoutItsEnabledState() {
        let enabled = SubstitutionRule(
            name: "Dr.",
            pattern: "\\bDr\\.",
            replacement: "Doctor",
            isRegex: true,
            caseSensitive: true
        )
        var disabled = enabled
        disabled.isEnabled = false

        XCTAssertEqual(
            enabled.accessibilitySummary,
            "Dr., Pattern: \\bDr\\., Replace with: Doctor, Regular expression, Case sensitive"
        )
        XCTAssertEqual(disabled.accessibilitySummary, enabled.accessibilitySummary)
    }

    /// An unnamed rule that deletes its matches says so, and a plain rule
    /// matching whole words says that; a regex rule never claims whole words.
    func testSummaryDescribesSkipsAndWholeWordMatching() {
        XCTAssertEqual(SubstitutionRule(pattern: "[1]").accessibilitySummary, "Pattern: [1], Action: skip")
        XCTAssertEqual(
            SubstitutionRule(pattern: "|", replacement: "I", wholeWord: true).accessibilitySummary,
            "Pattern: |, Replace with: I, Whole word only"
        )
        XCTAssertEqual(
            SubstitutionRule(pattern: "\\bI\\b", replacement: "one", isRegex: true, wholeWord: true).accessibilitySummary,
            "Pattern: \\bI\\b, Replace with: one, Regular expression"
        )
    }

    // MARK: - Rule commands

    /// The commands come in a fixed order under fixed names, and each names
    /// an SF Symbol that exists, so no row button is drawn blank.
    func testCommandsHaveFixedNamesAndExistingSymbols() {
        XCTAssertEqual(
            SubstitutionRuleCommand.allCases.map(\.title),
            ["Edit", "Move Up", "Move Down", "Delete"]
        )
        for command in SubstitutionRuleCommand.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: command.systemImage, accessibilityDescription: nil),
                command.title
            )
        }
    }

    /// Edit and Delete always apply. Move Up cannot act on the first rule,
    /// Move Down cannot act on the last, and a lone rule cannot move at all.
    func testMovesAreUnavailablePastTheEnds() {
        XCTAssertEqual(SubstitutionRuleCommand.available(at: 0, of: 3), [.edit, .moveDown, .delete])
        XCTAssertEqual(SubstitutionRuleCommand.available(at: 1, of: 3), [.edit, .moveUp, .moveDown, .delete])
        XCTAssertEqual(SubstitutionRuleCommand.available(at: 2, of: 3), [.edit, .moveUp, .delete])
        XCTAssertEqual(SubstitutionRuleCommand.available(at: 0, of: 1), [.edit, .delete])
    }

    /// Moves are announced with positions counted from one.
    func testMovedAnnouncementCountsPositionsFromOne() {
        XCTAssertEqual(
            SubstitutionsSettingsView.movedAnnouncement(ruleName: "Mr.", index: 2, count: 7),
            "Mr. moved to position 3 of 7"
        )
        XCTAssertEqual(
            SubstitutionsSettingsView.movedAnnouncement(ruleName: "Skip URLs", index: 0, count: 1),
            "Skip URLs moved to position 1 of 1"
        )
    }

    /// The footer names both ways to reorder, not only dragging.
    func testFooterExplainsBothWaysToReorder() {
        XCTAssertEqual(
            SubstitutionsSettingsView.reorderInstructions,
            "Use Move Up and Move Down, or drag, to reorder. Rules apply top to bottom."
        )
    }

    // MARK: - Moving from the list

    /// A Move command moves the rule one step and announces its new place,
    /// at high priority so VoiceOver speaks it straight away.
    func testMoveCommandMovesTheRuleAndAnnouncesItsNewPosition() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 4)
        let service = TextSubstitutionService(rules: rules)

        let recorder = recordingAnnouncements {
            SubstitutionsSettingsView.move(rules[3], .up, in: service)
            SubstitutionsSettingsView.move(rules[0], .down, in: service)
        }

        XCTAssertEqual(service.rules.map(\.name), ["B", "A", "D", "C"])
        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "D moved to position 3 of 4", priority: .high),
            VoiceOverAnnouncement(message: "A moved to position 2 of 4", priority: .high),
        ])
    }

    /// At an end of the list a Move command changes and announces nothing.
    func testMoveCommandAtAnEndStaysSilent() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let rules = makeRules(count: 2)
        let service = TextSubstitutionService(rules: rules)

        let recorder = recordingAnnouncements {
            SubstitutionsSettingsView.move(rules[0], .up, in: service)
            SubstitutionsSettingsView.move(rules[1], .down, in: service)
        }

        XCTAssertEqual(service.rules, rules)
        XCTAssertEqual(recorder.announcements, [])
    }

    /// Dragging one rule to a new place announces where it landed, just as
    /// the Move commands do.
    func testDraggingOneRuleAnnouncesItsNewPosition() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let service = TextSubstitutionService(rules: makeRules(count: 4))

        let recorder = recordingAnnouncements {
            // SwiftUI reports a drop just above the fourth rule as offset 3.
            SubstitutionsSettingsView.moveByDragging(from: [0], to: 3, in: service)
        }

        XCTAssertEqual(service.rules.map(\.name), ["B", "C", "A", "D"])
        XCTAssertEqual(try sandbox.savedRules(), service.rules)
        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "A moved to position 3 of 4", priority: .high)
        ])
    }

    /// A drop back in place, or a drag of several rules at once, moves as
    /// asked but announces nothing, having no single new place to report.
    func testDraggingInPlaceOrSeveralRulesStaysSilent() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let service = TextSubstitutionService(rules: makeRules(count: 4))

        let recorder = recordingAnnouncements {
            SubstitutionsSettingsView.moveByDragging(from: [1], to: 2, in: service)
            SubstitutionsSettingsView.moveByDragging(from: [0, 1], to: 4, in: service)
        }

        XCTAssertEqual(service.rules.map(\.name), ["C", "D", "A", "B"])
        XCTAssertEqual(recorder.announcements, [])
    }

    // MARK: - Rendered rows

    /// Each rendered row draws its enable checkbox, showing whether the rule
    /// is on, and all four command buttons, with Move Up dimmed on the first
    /// rule and Move Down on the last.
    func testRenderedRowsShowEveryControlAndDimImpossibleMoves() throws {
        var rules = makeRules(count: 3)
        rules[1].isEnabled = false
        let service = TextSubstitutionService(rules: rules)

        try withRenderedRows(of: service) { rows in
            XCTAssertEqual(rows.map { $0.checkbox.state == .on }, [true, false, true])
            XCTAssertEqual(rows.map(\.availableCommands), [
                [.edit, .moveDown, .delete],
                [.edit, .moveUp, .moveDown, .delete],
                [.edit, .moveUp, .delete],
            ])
        }
    }

    /// Pressing the first rule's rendered Move Down button moves that rule
    /// below the second and announces where it went.
    func testPressingRenderedMoveDownMovesTheRuleAndAnnouncesIt() throws {
        let sandbox = try SubstitutionFileSandbox.capture()
        defer { sandbox.restore() }
        let service = TextSubstitutionService(rules: makeRules(count: 3))

        try withRenderedRows(of: service) { rows in
            let moveDown = try XCTUnwrap(rows.first?.buttons[.moveDown])
            let recorder = recordingAnnouncements {
                moveDown.performClick(nil)
                // SwiftUI may deliver the button's action on a later turn
                // of the run loop.
                _ = waitUntil { service.rules.first?.name == "B" }
            }

            XCTAssertEqual(service.rules.map(\.name), ["B", "A", "C"])
            XCTAssertEqual(recorder.announcements, [
                VoiceOverAnnouncement(message: "A moved to position 2 of 3", priority: .high)
            ])
        }
    }

    // MARK: - Helpers

    /// `count` distinct plain rules named "A", "B", "C", and so on.
    private func makeRules(count: Int) -> [SubstitutionRule] {
        ["A", "B", "C", "D", "E", "F"].prefix(count).map { name in
            SubstitutionRule(name: name, pattern: name.lowercased(), replacement: name)
        }
    }

    /// One rule row as AppKit drew it: its checkbox and its command buttons.
    /// Main-actor isolated, like the AppKit controls it reads.
    @MainActor
    private struct RenderedRow {
        let checkbox: NSButton
        let buttons: [SubstitutionRuleCommand: NSButton]

        /// The commands whose buttons are not dimmed, in button order.
        var availableCommands: [SubstitutionRuleCommand] {
            SubstitutionRuleCommand.allCases.filter { buttons[$0]?.isEnabled == true }
        }
    }

    /// Render the Text settings tab for `service` offscreen and pass its
    /// rule rows, as AppKit drew them, to `body`.
    ///
    /// SwiftUI draws each row's checkbox and borderless buttons with AppKit
    /// buttons, in row order: the checkbox, then one button per command.
    /// The test is skipped should a later macOS stop drawing them that way.
    private func withRenderedRows(
        of service: TextSubstitutionService,
        _ body: ([RenderedRow]) throws -> Void
    ) throws {
        let buttonsPerRow = 1 + SubstitutionRuleCommand.allCases.count
        let expectedCounts = Array(repeating: buttonsPerRow, count: service.rules.count)

        try withHostedView(
            SubstitutionsSettingsView(service: service),
            size: NSSize(width: 600, height: 540),
            until: { renderedRowButtons(in: $0).map(\.count) == expectedCounts }
        ) { hostingView in
            let rowButtons = renderedRowButtons(in: hostingView)
            XCTAssertEqual(rowButtons.count, service.rules.count, "One rendered row per rule")
            if !rowButtons.isEmpty, rowButtons.allSatisfy(\.isEmpty) {
                throw XCTSkip("This macOS does not draw rule rows with AppKit buttons")
            }
            XCTAssertEqual(
                rowButtons.map(\.count), expectedCounts,
                "Each row draws a checkbox and one button per command"
            )
            guard rowButtons.map(\.count) == expectedCounts else { return }

            try body(rowButtons.map { buttons in
                RenderedRow(
                    checkbox: buttons[0],
                    buttons: Dictionary(uniqueKeysWithValues: zip(
                        SubstitutionRuleCommand.allCases,
                        buttons.dropFirst()
                    ))
                )
            })
        }
    }

    /// The AppKit buttons in each row of the list inside `hostingView`, row
    /// by row and in drawing order; empty until the list has rows.
    private func renderedRowButtons(in hostingView: NSView) -> [[NSButton]] {
        guard let outline = descendants(of: hostingView, as: NSOutlineView.self).first else {
            return []
        }
        return (0..<outline.numberOfRows).map { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                .map { descendants(of: $0, as: NSButton.self) } ?? []
        }
    }

    /// Every view of type `T` inside `view`, depth first in subview order.
    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T {
                found.append(match)
            }
            found += descendants(of: subview, as: type)
        }
        return found
    }
}

/// Keeps the hosted test root's substitutions.json as each test found it.
///
/// An injected `TextSubstitutionService` saves to that same file, so a test
/// that changes rules records the file first and puts it back afterwards.
/// The hosted app's shared rules stay in memory and never reread the file.
private struct SubstitutionFileSandbox {
    /// Raised when the rules file is not inside the isolated test root.
    struct UnisolatedRulesFile: Error {
        let path: String
    }

    /// substitutions.json in the hosted test root.
    let url: URL
    /// The file's bytes when captured, or nil when it did not exist.
    private let originalData: Data?

    /// Records the rules file, refusing to touch one outside the temporary
    /// directory where hosted tests keep their isolated data root.
    static func capture() throws -> SubstitutionFileSandbox {
        let url = TextMouthPaths.substitutionsFile
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            throw UnisolatedRulesFile(path: url.path)
        }
        return SubstitutionFileSandbox(url: url, originalData: try? Data(contentsOf: url))
    }

    /// Whether a rules file exists now.
    var hasSavedRules: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The rules as last saved, in saved order.
    func savedRules() throws -> [SubstitutionRule] {
        try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: url))
    }

    /// Deletes the rules file, so a test can tell whether anything saves.
    func removeSavedRules() throws {
        if hasSavedRules {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Puts back the original bytes, or removes the file if there was none.
    func restore() {
        if let originalData {
            try? originalData.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
