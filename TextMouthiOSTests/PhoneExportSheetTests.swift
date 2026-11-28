import SwiftUI
import UIKit
import XCTest
@testable import TextMouth

/// The iPhone's Export sheet, hosted as the app draws it (FR31): the real
/// `PhoneExportSheet` over a text book whose package is in the test's own data
/// folder, and its model as the sheet makes it.
///
/// What the sheet says, in what order, with which value and hint, is read by
/// the interface tests on GitHub (`ExportUITests`), since only an assistive
/// session or XCUITest builds SwiftUI's accessibility tree; and every word and
/// every decision about the bar is the plain types' own, which the Mac's
/// test host tests (`PhoneExportOfferTests`). What a hosted view shows here is
/// what UIKit draws of it: a switch for each kind, on or off. So these tests
/// show that the sheet lists, finds the book's kinds, spoken audio among them,
/// starts with the first kind on, and still draws them at the largest text size.
///
/// Nothing here exports, plays, types, or speaks.
@MainActor
final class PhoneExportSheetTests: XCTestCase {

    // MARK: - Fixtures

    /// The windows a test opened, so each closes at the end of the test.
    private var windows: [UIWindow] = []

    /// Closes every window the test opened.
    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        try await super.tearDown()
    }

    /// A text book whose package, in the test's own data folder, holds its
    /// own file and its content.md, so that it offers its original file, its
    /// Markdown, and its plain text, and the iPhone's offer leaves out spoken
    /// audio. Removed when the test ends.
    private func makeBook(cacheText: String = "<!-- chapter: First -->\n# First\n\nOne two three.\n") throws -> Book {
        let directory = try makeSandboxDirectory("PhoneExportSheetSource")
        let file = directory.appendingPathComponent("Harbour Pilots.md")
        try Data("# First\n\nOne two three.\n".utf8).write(to: file)
        let book = Book(
            title: "Harbour Pilots",
            format: .markdown,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: "PhoneExportSheet-\(UUID().uuidString).tmb"
        )
        let cache = MarkdownCacheService.cacheURL(for: book)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(cacheText.utf8).write(to: cache)
        let package = book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        return book
    }

    /// Shows the sheet for `book` in a phone-sized window of the app's scene,
    /// at the text size `size` when it is given.
    private func host(_ book: Book, textSize size: UIContentSizeCategory? = nil) throws -> UIHostingController<AnyView> {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host has no window scene"
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let sheet = PhoneExportSheet(
            books: [book],
            library: library,
            beginHold: { _ in {} },
            defaults: makeSandboxedPreferences("PhoneExportSheet")
        )
        let controller = UIHostingController(rootView: AnyView(sheet))
        if let size { controller.traitOverrides.preferredContentSizeCategory = size }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        return controller
    }

    /// Every switch under `root`.
    private func switches(in root: UIView) -> [UISwitch] {
        var found: [UISwitch] = []
        var pending: [UIView] = [root]
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if let toggle = view as? UISwitch { found.append(toggle) }
        }
        return found
    }

    /// Lets SwiftUI lay the sheet out and the model list the book, until
    /// `expected` switches are drawn or the wait runs out, and returns them in
    /// the order the screen draws them, top to bottom.
    private func switchesDrawn(by controller: UIViewController, expected: Int) -> [UISwitch] {
        let drawn = eventually(within: 20) {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return switches(in: controller.view).count >= expected
        }
        XCTAssertTrue(drawn, "The sheet drew \(switches(in: controller.view).count) switches, expected \(expected)")
        return switches(in: controller.view).sorted {
            $0.convert($0.bounds, to: controller.view).minY < $1.convert($1.bounds, to: controller.view).minY
        }
    }

    // MARK: - Stop

    /// A book whose text nests quotes past the limit makes its export ask the person what to do, as an alert of the
    /// sheet's own; Stop, pressed while the question is up, answers it Cancel Export, so the export ends as stopped,
    /// nothing is written, and no question is left. This is the iPhone's half of `BookExportModel.init`.
    func testStopAnswersCancelExportToTheQuestionTheExportWaitsOn() async throws {
        let deep = DeepMarkdown.quotes(MarkupGuard.Limits.standard.deepestNesting + 1) + "\n"
        let book = try makeBook(cacheText: deep)
        let folder = try makeSandboxDirectory("PhoneExportSheetStop")
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let model = BookExportModel(
            books: [book],
            library: library,
            destination: folder,
            deepChapterPrompting: .standard,
            offering: PhoneExportOffer.kinds,
            delivery: .coordinatedCopy
        )
        await model.load()
        model.setChecked(true, for: .markdown)
        model.setChecked(false, for: .originalFile)
        model.setConversionID("html", for: .markdown)
        let prompt = try XCTUnwrap(model.questionPrompt, "the iPhone's model has no prompt of its own")

        let exporting = Task { await model.export() }
        let asked = await eventually(timeout: 30) { prompt.pending != nil }
        XCTAssertTrue(asked, "the export never asked about the chapter")
        model.stop()
        let outcome = await exporting.value

        XCTAssertEqual(outcome?.wasCancelled, true)
        XCTAssertEqual(outcome?.exported, [])
        XCTAssertNil(prompt.pending, "the question stayed up after Stop")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - The Kinds

    /// The sheet lists the book's kinds as switches: its original file, its
    /// Markdown, its plain text, and its spoken audio, the first on and the
    /// rest off, as the Mac's dialog starts.
    func testTheSheetListsASwitchForEachKindTheIPhoneOffers() throws {
        let controller = try host(try makeBook())

        let toggles = switchesDrawn(by: controller, expected: 4)

        XCTAssertEqual(toggles.count, 4, "The fourth switch is spoken audio, offered since phase 2")
        XCTAssertEqual(toggles.map(\.isOn), [true, false, false, false])
        // The three the book's files give are enabled; spoken audio is as available as the book's text cache.
        XCTAssertTrue(toggles.prefix(3).allSatisfy(\.isEnabled))
    }

    /// At the largest text size the sheet still draws its first switch, on:
    /// the rows are tall there and a list draws only those on screen, so no
    /// more is counted on.
    func testTheSheetStillListsTheKindsAtTheLargestTextSize() throws {
        let controller = try host(try makeBook(), textSize: .accessibilityExtraExtraExtraLarge)

        let toggles = switchesDrawn(by: controller, expected: 1)

        XCTAssertGreaterThanOrEqual(toggles.count, 1)
        XCTAssertEqual(toggles.first?.isOn, true)
    }
}
