import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

// MARK: - FR03 Feed Interface Test Support
//
// What the feed interface's hosted tests share: finding the AppKit controls
// SwiftUI draws for a sheet or a settings pane, and the elements VoiceOver's
// focus requests look for.

extension XCTestCase {
    /// Starts `world`'s engine and turns the run loop until what it starts
    /// has finished, as `world.start()` awaits it; fails the test, and
    /// returns false, when that takes too long. The feed sheets' tests of
    /// the keyboard are synchronous: they turn the run loop while a hosted
    /// view is alive, and under an async test that turning cannot run the
    /// main actor's work, so a button's Task would never finish.
    @MainActor
    func startTurningTheRunLoop(_ world: FeedTestWorld, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let finished = CallLog<Bool>()
        Task {
            await world.start()
            finished.record(true)
        }
        let started = waitUntil(timeout: 10) { !finished.calls.isEmpty }
        XCTAssertTrue(started, "the engine's start did not finish", file: file, line: line)
        return started
    }

    /// The radio buttons SwiftUI drew in `view` for a radio-group picker:
    /// how many, and the place of the one chosen. SwiftUI draws each as an
    /// AppKit button with no title of its own, as it draws a checkbox, its
    /// words beside it, or as the cells of a matrix; in a view with no
    /// checkbox, every untitled button is a radio button.
    @MainActor
    func feedRadioChoices(in view: NSView) -> (count: Int, chosen: Int?) {
        let buttons = untitledButtons(in: view)
        if !buttons.isEmpty {
            return (buttons.count, buttons.firstIndex { $0.state == .on })
        }
        for matrix in descendants(of: view, as: NSMatrix.self) where !matrix.cells.isEmpty {
            return (matrix.cells.count, matrix.selectedRow >= 0 ? matrix.selectedRow : nil)
        }
        return (0, nil)
    }

    /// The checkboxes SwiftUI drew in `view`, in reading order: AppKit
    /// buttons with no title of their own, their words drawn beside them, as
    /// the Export dialog's tests find them. An accessibility role would say
    /// more, but SwiftUI gives its controls one only for a connected
    /// assistive app.
    ///
    /// Their states show the settings, but a test cannot press them: SwiftUI
    /// gives these buttons no action, so `performClick` changes nothing.
    @MainActor
    func feedCheckboxes(in view: NSView) -> [NSButton] {
        untitledButtons(in: view)
    }

    /// The AppKit buttons in `view` without a title, which are SwiftUI's
    /// checkboxes and radio buttons, leaving out pop-up buttons, in reading
    /// order: top to bottom, then left to right, as the window shows them,
    /// since SwiftUI does not promise to keep its views in that order.
    @MainActor
    private func untitledButtons(in view: NSView) -> [NSButton] {
        let buttons = descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) && $0.title.isEmpty }
        // Each button's frame in window coordinates, in which y grows upward.
        let placed = buttons.map { (button: $0, frame: $0.convert($0.bounds, to: nil)) }
        return placed
            .sorted { first, second in
                let (firstRow, secondRow) = (first.frame.midY.rounded(), second.frame.midY.rounded())
                return firstRow != secondRow ? firstRow > secondRow : first.frame.minX < second.frame.minX
            }
            .map { $0.button }
    }

    /// Every accessibility element below `root` whose identifier is
    /// `identifier`, such as the one a VoiceOver focus request looks for.
    @MainActor
    func feedElements(identified identifier: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityIdentifier() == identifier ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap {
            feedElements(identified: identifier, in: $0)
        }
    }
}

/// Every item of `menu` and of its submenus, depth first.
@MainActor
func feedMenuItems(of menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in [item] + (item.submenu.map(feedMenuItems(of:)) ?? []) }
}
