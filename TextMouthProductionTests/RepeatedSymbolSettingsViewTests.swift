import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Repeated Symbols group of the Text settings: the words each control
/// speaks, the threshold and Never collapse logic, the reset action, and the
/// group as AppKit renders it, read through accessibility the way VoiceOver
/// reads it.
///
/// AppKit exposes the picker, the stepper, and the text fields itself, so
/// their labels, values, and hints are read directly. SwiftUI builds the
/// accessibility labels of its own toggles and buttons only for a connected
/// assistive app, so their words are pinned by the wording tests, and the
/// checkbox is clicked as the AppKit button SwiftUI draws for it. Every
/// service here has no preferences store, so nothing a test changes is
/// saved.
@MainActor
final class RepeatedSymbolSettingsViewTests: XCTestCase {

    // MARK: - Wording

    /// Each picker option names its style and says what it does at the
    /// threshold, and the collapsing styles say they are off while Never
    /// collapse is checked.
    func testStyleOptionsDescribeThemselves() {
        XCTAssertEqual(
            RepeatedSymbolStyle.allCases.map { $0.optionTitle(threshold: 4) },
            [
                "Repeat each symbol: every symbol is read as written",
                "Say how many: runs of 4 or more are read as a count",
                "Leave out: runs of 4 or more are skipped, with a pause",
            ]
        )
        XCTAssertEqual(
            RepeatedSymbolStyle.sayCount.optionTitle(threshold: 12),
            "Say how many: runs of 12 or more are read as a count"
        )
        XCTAssertEqual(
            RepeatedSymbolStyle.allCases.map { $0.optionTitle(threshold: -1) },
            [
                "Repeat each symbol: every symbol is read as written",
                "Say how many: off while Never collapse is checked",
                "Leave out: off while Never collapse is checked",
            ]
        )
    }

    /// Every control has its own explicit label and a hint, and the symbols
    /// field's hint explains what its characters mean.
    func testEveryControlHasAnExplicitLabelAndHint() {
        typealias Settings = RepeatedSymbolsSettingsView
        let labels = [Settings.styleLabel, Settings.thresholdLabel, Settings.neverCollapseLabel, Settings.symbolsLabel, Settings.resetLabel]
        XCTAssertEqual(Set(labels).count, labels.count, "no two controls share a label")
        XCTAssertEqual(Settings.thresholdLabel, "Collapse runs of at least")
        XCTAssertEqual(Settings.neverCollapseLabel, "Never collapse: read every symbol")
        XCTAssertEqual(Settings.thresholdValue(4), "4 symbols")
        let hints = [
            Settings.styleHint, Settings.thresholdFieldHint, Settings.thresholdStepperHint,
            Settings.neverCollapseHint, Settings.symbolsHint, Settings.resetHint,
        ]
        XCTAssertFalse(hints.contains(where: \.isEmpty))
        for words in ["Each character listed can form a run", "Spaces are ignored", "counts once", "letters and digits"] {
            XCTAssertTrue(Settings.symbolsHint.contains(words), words)
        }
    }

    // MARK: - Threshold logic and reset

    /// Never collapse is the threshold -1. While it is checked, the field
    /// and stepper show the threshold unchecking it restores; checking it
    /// stores -1 and unchecking it restores that threshold.
    func testNeverCollapseStoresMinusOneAndRestoresTheLastThreshold() {
        typealias Settings = RepeatedSymbolsSettingsView
        XCTAssertTrue(Settings.neverCollapses(-1))
        XCTAssertFalse(Settings.neverCollapses(2))
        XCTAssertEqual(Settings.collapsingThreshold(-1), 4, "no threshold to restore yet: the default")
        XCTAssertEqual(Settings.collapsingThreshold(9), 9)
        XCTAssertEqual(Settings.displayedThreshold(-1, remembering: 9), 9)
        XCTAssertEqual(Settings.displayedThreshold(6, remembering: 9), 6)
        XCTAssertEqual(Settings.threshold(neverCollapse: true, remembering: 9), -1)
        XCTAssertEqual(Settings.threshold(neverCollapse: false, remembering: 9), 9)
    }

    /// Reset to Default restores the default list, returns it for the field
    /// to show, and tells VoiceOver at high priority, since the button keeps
    /// focus and the field's change is not spoken.
    func testResetRestoresTheDefaultSymbolsAndAnnouncesIt() {
        let service = TextSubstitutionService(rules: [])
        service.repeatedSymbolSet = "~"

        var shown = ""
        let recorder = recordingAnnouncements {
            shown = RepeatedSymbolsSettingsView.resetSymbols(in: service)
        }

        XCTAssertEqual(service.repeatedSymbolSet, SettingsPolicy.repeatedSymbolSet.defaultValue)
        XCTAssertEqual(shown, SettingsPolicy.repeatedSymbolSet.defaultValue)
        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "Symbols reset to the default list", priority: .high)
        ])
    }

    // MARK: - Rendered controls

    /// VoiceOver finds the style picker by its label and hint, hearing the
    /// chosen option's description as its value; the threshold stepper by
    /// its label, once, its value in symbols, and its hint; and both text
    /// fields by their labels, values, and hints.
    func testRenderedControlsSpeakTheirLabelsValuesAndHints() throws {
        let service = TextSubstitutionService(rules: [])

        try withHostedControls(RepeatedSymbolsSettingsView(service: service)) { controls in
            let picker = try control(labelled: RepeatedSymbolsSettingsView.styleLabel, in: controls)
            XCTAssertEqual(picker.role, .popUpButton)
            XCTAssertEqual(picker.hint, RepeatedSymbolsSettingsView.styleHint)
            XCTAssertEqual(picker.element.accessibilityValue() as? String, "Say how many: runs of 4 or more are read as a count")

            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor }, "\(controls.map(\.label))")
            XCTAssertEqual(stepper.label, "Collapse runs of at least")
            XCTAssertEqual(stepper.valueDescription, "4 symbols")
            XCTAssertEqual(stepper.hint, RepeatedSymbolsSettingsView.thresholdStepperHint)

            let fields = controls.filter { $0.role == .textField }
            let threshold = try XCTUnwrap(fields.first { $0.label == RepeatedSymbolsSettingsView.thresholdLabel }, "\(fields.map(\.label))")
            XCTAssertEqual(threshold.element.accessibilityValue() as? String, "4")
            XCTAssertEqual(threshold.hint, RepeatedSymbolsSettingsView.thresholdFieldHint)
            let symbols = try XCTUnwrap(fields.first { $0.label == RepeatedSymbolsSettingsView.symbolsLabel }, "\(fields.map(\.label))")
            XCTAssertEqual(symbols.element.accessibilityValue() as? String, SettingsPolicy.repeatedSymbolSet.defaultValue)
            XCTAssertEqual(symbols.hint, RepeatedSymbolsSettingsView.symbolsHint)
        }
    }

    /// Raising the threshold with the stepper, as VoiceOver's increment
    /// action does, stores it, speaks the new value, and rewords the
    /// picker's options for it.
    func testTheStepperRaisesTheThresholdAndRewordsTheOptions() throws {
        let service = TextSubstitutionService(rules: [])

        try withHostedControls(RepeatedSymbolsSettingsView(service: service)) { controls in
            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor })
            let picker = try control(labelled: RepeatedSymbolsSettingsView.styleLabel, in: controls)

            _ = stepper.element.accessibilityPerformIncrement()

            XCTAssertEqual(service.repeatedSymbolThreshold, 5)
            XCTAssertTrue(waitUntil { stepper.element.accessibilityValueDescription() == "5 symbols" })
            XCTAssertTrue(waitUntil {
                picker.element.accessibilityValue() as? String == "Say how many: runs of 5 or more are read as a count"
            })
        }
    }

    /// While Never collapse is checked, the threshold field and stepper are
    /// dimmed and keep showing the threshold unchecking it restores, and the
    /// picker says the collapsing styles are off; once unchecked, both are
    /// enabled again at that threshold.
    ///
    /// SwiftUI does not put its checkbox in the accessibility tree without a
    /// connected assistive app, so the test stores what checking and
    /// unchecking it store, computed as its binding computes them.
    func testNeverCollapseDimsTheThresholdControls() throws {
        typealias Settings = RepeatedSymbolsSettingsView
        let service = TextSubstitutionService(rules: [])
        service.repeatedSymbolThreshold = 6

        try withHostedControls(Settings(service: service)) { controls in
            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor })
            let field = try control(labelled: Settings.thresholdLabel, in: controls.filter { $0.role == .textField })
            let picker = try control(labelled: Settings.styleLabel, in: controls)

            service.repeatedSymbolThreshold = Settings.threshold(neverCollapse: true, remembering: 6)
            XCTAssertEqual(service.repeatedSymbolThreshold, -1)
            XCTAssertTrue(waitUntil { !stepper.element.isAccessibilityEnabled() }, "the stepper is dimmed")
            XCTAssertTrue(waitUntil { !field.element.isAccessibilityEnabled() }, "the field is dimmed")
            XCTAssertEqual(stepper.element.accessibilityValueDescription(), "6 symbols")
            XCTAssertEqual(field.element.accessibilityValue() as? String, "6")
            XCTAssertTrue(waitUntil {
                picker.element.accessibilityValue() as? String == "Say how many: off while Never collapse is checked"
            })

            service.repeatedSymbolThreshold = Settings.threshold(neverCollapse: false, remembering: 6)
            XCTAssertEqual(service.repeatedSymbolThreshold, 6)
            XCTAssertTrue(waitUntil { stepper.element.isAccessibilityEnabled() })
            XCTAssertTrue(waitUntil { field.element.isAccessibilityEnabled() })
            XCTAssertTrue(waitUntil {
                picker.element.accessibilityValue() as? String == "Say how many: runs of 6 or more are read as a count"
            })
        }
    }

    /// The symbols field shows a list changed elsewhere, such as in
    /// config.json, as soon as it changes.
    func testTheSymbolsFieldFollowsAListChangedElsewhere() throws {
        let service = TextSubstitutionService(rules: [])

        try withHostedControls(RepeatedSymbolsSettingsView(service: service)) { controls in
            let symbols = try control(labelled: RepeatedSymbolsSettingsView.symbolsLabel, in: controls)

            service.repeatedSymbolSet = "~="

            XCTAssertTrue(waitUntil { symbols.element.accessibilityValue() as? String == "~=" })
        }
    }

    /// The group is part of the Text settings tab, below the substitution
    /// rules, where the user looks for pronunciation settings.
    func testTheTextTabShowsTheGroup() {
        let service = TextSubstitutionService(rules: [SubstitutionRule(name: "Mr.", pattern: "Mr.", replacement: "Mister")])

        withHostedView(
            SubstitutionsSettingsView(service: service),
            size: NSSize(width: 600, height: 540),
            until: { hostingView in
                self.accessibleControls(in: hostingView).contains { $0.label == RepeatedSymbolsSettingsView.styleLabel }
            }
        ) { hostingView in
            let labels = accessibleControls(in: hostingView).map(\.label)
            XCTAssertTrue(labels.contains(RepeatedSymbolsSettingsView.styleLabel), "\(labels)")
            XCTAssertTrue(labels.contains(RepeatedSymbolsSettingsView.thresholdLabel), "\(labels)")
            XCTAssertTrue(labels.contains(RepeatedSymbolsSettingsView.symbolsLabel), "\(labels)")
        }
    }

    // MARK: - Helpers

    /// The control VoiceOver finds under `label`, failing with every label
    /// found when there is none.
    private func control(labelled label: String, in controls: [AccessibleControl]) throws -> AccessibleControl {
        try XCTUnwrap(controls.first { $0.label == label }, "no control labelled \(label): \(controls.map(\.label))")
    }
}
