import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// What AppKit's own type select does in the Library list, which the first
/// choice of the Leading articles setting keeps, and which the second and
/// third choices copy (TITLE-ARTICLES-RESEARCH-2026-11-13.md): the findings
/// `LibraryTypeSelectProbeTests` made on GitHub's runner and printed, held
/// as assertions so a macOS update that changes them fails a test rather
/// than going unseen.
///
/// - A new search starts at the row after the selected one and wraps, so a
///   letter typed again after a pause goes on to the next title with it, and
///   a lone match stays where it is.
/// - Typed letters add up for a little over a second (between 1.2 and 1.3
///   seconds on the runner) and start afresh after that.
///
/// Every key typed matches some row however AppKit searches, and goes to a
/// table that has the keyboard, so nothing beeps. The tests use real time,
/// since AppKit reads the clock (about 17 seconds in all), and the pauses are
/// far enough from the measured edge, 1.0 and 1.6 seconds against 1.2 and
/// 1.3, that a busy machine's delays cannot cross it. The setting's default
/// is the first choice, and the tests write no preference and no default.
@MainActor
final class LibraryTypeSelectBehaviorTests: XCTestCase {

    /// How long to wait for a typed search to end, with AppKit's interval
    /// (about 1.25 seconds) well past.
    private static let searchEnds: TimeInterval = 1.7

    /// A hosted Library list of `titles` in their manual order, with its
    /// table holding the keyboard, and the number of rows above the books
    /// (the Books section's header).
    @MainActor
    private struct Hosted {
        let window: NSWindow
        let view: NSView
        let table: NSTableView
        let titles: [String]

        /// The title of the book on the selected row, or nil for none.
        var selectedTitle: String? {
            let book = table.selectedRow - (table.numberOfRows - titles.count)
            return titles.indices.contains(book) && table.selectedRow >= 0 ? titles[book] : nil
        }

        /// Selects the book titled `title`, as a click would.
        func select(_ title: String) throws {
            let book = try XCTUnwrap(titles.firstIndex(of: title), "no book \(title)")
            table.selectRowIndexes(IndexSet(integer: table.numberOfRows - titles.count + book), byExtendingSelection: false)
        }
    }

    /// Hosts the Library list of `titles` in the first choice, draws it for
    /// `settleSeconds`, and gives its table the keyboard; skips where this
    /// macOS gives an offscreen window's list none.
    private func host(titles: [String], settleSeconds: TimeInterval = 0.5) throws -> Hosted {
        let folder = "Type Select"
        let (model, settings) = LibraryTitleTypingTests.shelf(of: titles, in: folder)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(folder),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        settle(hosted.hostingView, seconds: settleSeconds)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
            takeDown(hosted.window)
            throw XCTSkip("This macOS gives an offscreen window's list no keyboard focus, so nothing is typed")
        }
        return Hosted(window: hosted.window, view: hosted.hostingView, table: table, titles: titles)
    }

    /// Types `character` into the hosted list's window, then lets the list
    /// draw what it selected.
    private func type(_ character: Character, into hosted: Hosted) throws {
        hosted.window.sendEvent(try LibraryTitleTypingTests.keyDown(character, in: hosted.window))
        flush(hosted.view)
    }

    /// The first choice is in force: the setting's default, which these tests
    /// rely on and do not write.
    private func requireTheFirstChoice() throws {
        try XCTSkipUnless(
            LeadingArticles.preference.read(from: TextMouthRuntime.current.preferences) == .partOfTitle,
            "The Leading articles setting is not at its default here, so AppKit's own type select is not in force"
        )
    }

    // MARK: - Where a Search Starts

    /// AppKit's search starts after the selected row and wraps. With Banana
    /// Republic and then Avocado Toast selected, A goes on to A Tale of Two
    /// Cities and then wraps to Apple Pie, not back to the top each time; a
    /// B with Banana Republic selected stays on it, the lone match; a search
    /// with nothing selected begins at the top. Each search follows a pause
    /// that ends the one before.
    func testAppKitsTypeSelectSearchesAfterTheSelectionAndWraps() throws {
        try requireTheFirstChoice()
        let hosted = try host(titles: ["Apple Pie", "Banana Republic", "Avocado Toast", "A Tale of Two Cities"])
        defer { takeDown(hosted.window) }
        var findings: [String] = []
        /// Types `character` after the last search has ended and records what it selected, against `expected`.
        func expect(_ character: Character, selecting expected: String, after: String) throws {
            settle(hosted.view, seconds: Self.searchEnds)
            try type(character, into: hosted)
            if hosted.selectedTitle != expected {
                findings.append("\(character) \(after): \(hosted.selectedTitle ?? "no row") was selected, not \(expected)")
            }
        }

        // From nothing selected, the top: Apple Pie is the first A.
        hosted.table.deselectAll(nil)
        try expect("a", selecting: "Apple Pie", after: "with nothing selected")
        // After the selection: from Banana Republic, the next A is Avocado Toast; from Avocado Toast,
        // A Tale of Two Cities; from that, the wrap round to Apple Pie.
        try hosted.select("Banana Republic")
        try expect("a", selecting: "Avocado Toast", after: "with Banana Republic selected")
        try expect("a", selecting: "A Tale of Two Cities", after: "with Avocado Toast selected")
        try expect("a", selecting: "Apple Pie", after: "with A Tale of Two Cities selected, the last row")
        // A lone match stays: the only B, with Banana Republic selected and again.
        try hosted.select("Banana Republic")
        try expect("b", selecting: "Banana Republic", after: "with Banana Republic, the only B, selected")
        XCTAssertEqual(findings, [])
    }

    // MARK: - When Typed Letters Add Up

    /// Typed letters add up for a little over a second and start afresh
    /// after that: T then R is Treasure Island while the R comes 1.0 seconds
    /// after, Robinson Crusoe when it comes 1.6 seconds after (AppKit's time
    /// is between 1.2 and 1.3 on the runner). Each try is a fresh list,
    /// drawn after a wait that ends any search AppKit keeps for all its tables.
    func testTypedLettersAddUpAtOneSecondAndStartAfreshAtOnePointSix() throws {
        try requireTheFirstChoice()
        let titles = ["Apple Pie", "Treasure Island", "Robinson Crusoe"]
        var findings: [String] = []
        for (gap, expected) in [(1.0, "Treasure Island"), (1.6, "Robinson Crusoe")] {
            let hosted = try host(titles: titles, settleSeconds: Self.searchEnds)
            defer { takeDown(hosted.window) }
            try type("t", into: hosted)
            settle(hosted.view, seconds: gap)
            try type("r", into: hosted)
            if hosted.selectedTitle != expected {
                findings.append("T then R \(gap) seconds apart selected \(hosted.selectedTitle ?? "no row"), not \(expected)")
            }
        }
        XCTAssertEqual(findings, [])
    }
}
