import SwiftUI
import UIKit
import XCTest
@testable import TextMouth

/// The phone's text fields grow with the text size, and the one thing the
/// accessibility audit objects to is SwiftUI's, not the app's (A11Y-GOTO).
///
/// Apple's audit flags each SwiftUI `TextField` "Dynamic Type font sizes are
/// partially unsupported. User will not be able to change the font size of this
/// UITextField". It checks UIKit's `adjustsFontForContentSizeCategory`, which
/// SwiftUI leaves off on the UITextField it draws, though the text grows (an
/// Apple DTS engineer, developer.apple.com/forums/thread/828525, June 2026).
/// The audit's finding is therefore accepted (`Accepted.swiftUITextField` in
/// `TextMouthUITestCase`), and these tests keep the acceptance honest:
///
/// - each of the real Go To, Search, Sleep Timer, and Book Information sheets
///   is hosted in a window, and the font of each of its text inputs must have
///   a text style and grow at the largest text size (a fixed font would not);
/// - a canary says SwiftUI's switch is still off. If a later iOS turns it on,
///   the canary fails, and the accepted findings can go.
///
/// Nothing here plays, types, or speaks. The sheets are the real ones, over a
/// reader of a text book held in memory.
@MainActor
final class PhoneTextFieldScalingTests: XCTestCase {

    // MARK: - Fixtures

    /// The largest size iOS offers.
    private let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge

    /// The least a scaling font must grow from the default size to `largest`:
    /// iOS's body font goes from 17 to 53 points, 3.1 times; the bound is well
    /// below that and well above 1 (a font that does not scale).
    private let leastGrowth: CGFloat = 2

    /// The windows a test opened, so each closes at the end of the test.
    private var windows: [UIWindow] = []

    /// Closes every window the test opened.
    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        try await super.tearDown()
    }

    /// Shows `view` in a phone-sized window of the app's scene (the bundle is
    /// hosted in the app, which always has one), and waits for SwiftUI to make
    /// its UIKit views.
    private func host(_ view: some View) throws -> UIHostingController<AnyView> {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host has no window scene"
        )
        let controller = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        settle(controller)
        return controller
    }

    /// Lets SwiftUI lay the view out and the main queue run what it was given.
    private func settle(_ controller: UIViewController) {
        for _ in 0..<4 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
    }

    /// Every UITextField and UITextView under `root`.
    private func textInputs(in root: UIView) -> [UIView] {
        var found: [UIView] = []
        var pending: [UIView] = [root]
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if view is UITextField || view is UITextView { found.append(view) }
        }
        return found
    }

    /// The font of a UITextField or UITextView, or nil.
    private func font(of input: UIView) -> UIFont? {
        (input as? UITextField)?.font ?? (input as? UITextView)?.font
    }

    /// Whether a UITextField or UITextView adjusts its font for the text size.
    private func adjusts(_ input: UIView) -> Bool {
        (input as? UITextField)?.adjustsFontForContentSizeCategory
            ?? (input as? UITextView)?.adjustsFontForContentSizeCategory
            ?? false
    }

    /// Whether `font` was vended with a text style, which is what makes it
    /// scale: a text style's font carries a descriptor attribute that begins
    /// "UICTFontTextStyle" ("UICTFontTextStyleBody", seen in a GitHub run's
    /// log), and a fixed one has none, or a plain usage such as
    /// "CTFontRegularUsage".
    private func hasTextStyle(_ font: UIFont) -> Bool {
        guard let usage = font.fontDescriptor.object(forKey: .textStyle) as? String else { return false }
        return usage.hasPrefix("UICTFontTextStyle")
    }

    /// A book of one chapter held in memory.
    private func makeBook() -> Book {
        Book(
            title: "Weather Notes",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-weather-notes.txt",
            md5Hash: UUID().uuidString
        )
    }

    /// A stopped reader of a text book held in memory: nothing plays and
    /// nothing is read from disk.
    private func makeReader() -> ReaderViewModel {
        let book = makeBook()
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false)
        )
        let chapter = Chapter(
            title: "Morning",
            text: "Clouds came early. The wind rose at noon.",
            headings: [Heading(level: 1, text: "Morning", chapterIndex: 0, characterOffset: 0)]
        )
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: [chapter])
        reader.isLoading = false
        return reader
    }

    /// Checks that each of `expected` text inputs of the sheet named `sheet`,
    /// hosted from `make`, has a font made from a text style and that the font
    /// grows at least `leastGrowth` times when the text size changes under the
    /// open sheet. Every shortfall of every input is reported at once.
    private func assertEveryInputGrows<Sheet: View>(_ sheet: String, expected: Int, make: () -> Sheet) throws {
        let controller = try host(make())
        let inputs = textInputs(in: controller.view)
        XCTAssertEqual(inputs.count, expected, "\(sheet) has \(inputs.count) text inputs, expected \(expected)")

        var misses: [String] = []
        var smallSizes: [CGFloat] = []
        for (index, input) in inputs.enumerated() {
            let kind = String(describing: type(of: input))
            if let font = font(of: input) {
                smallSizes.append(font.pointSize)
                if !hasTextStyle(font) { misses.append("input \(index) (\(kind)) has a font with no text style: \(font)") }
            } else {
                misses.append("input \(index) (\(kind)) has no font")
                smallSizes.append(0)
            }
        }

        // The text size changes under the same window, as the Larger Text
        // setting would change it.
        controller.traitOverrides.preferredContentSizeCategory = largest
        settle(controller)
        let grown = textInputs(in: controller.view)
        XCTAssertEqual(grown.count, inputs.count, "\(sheet) changed its text inputs when the text size changed")
        for (index, input) in grown.enumerated() where index < smallSizes.count {
            let before = smallSizes[index]
            let after = font(of: input)?.pointSize ?? 0
            if !(before > 0 && after >= before * leastGrowth) {
                misses.append("input \(index) went from \(before) to \(after) points at the largest size, less than \(leastGrowth) times")
            }
        }
        XCTAssertEqual(misses, [], "\(sheet): \(misses.joined(separator: "; "))")
    }

    // MARK: - The Phone's Sheets

    /// The Go To sheet's Percent and Time fields (a book of no pages has no
    /// Page field): the fields of A11Y-GOTO.
    func testTheGoToSheetsFieldsGrowWithTheTextSize() throws {
        let reader = makeReader()
        try assertEveryInputGrows("The Go To sheet", expected: 2) {
            PhoneGoToSheet(reader: reader, farewell: PhoneSheetFarewell(), noteJumped: {})
        }
    }

    /// The Search in Book sheet's one field.
    func testTheSearchSheetsFieldGrowsWithTheTextSize() throws {
        let reader = makeReader()
        try assertEveryInputGrows("The Search in Book sheet", expected: 1) {
            PhoneSearchSheet(reader: reader, farewell: PhoneSheetFarewell(), noteJumped: {})
        }
    }

    /// The Sleep Timer sheet's custom minutes field.
    func testTheSleepTimerSheetsFieldGrowsWithTheTextSize() throws {
        let reader = makeReader()
        try assertEveryInputGrows("The Sleep Timer sheet", expected: 1) {
            PhoneSleepTimerSheet(reader: reader, farewell: PhoneSheetFarewell())
        }
    }

    /// Book Information's title and author, fields that grow to several lines
    /// (a UITextView, where a one-line field is a UITextField).
    func testTheBookInformationSheetsFieldsGrowWithTheTextSize() throws {
        let book = makeBook()
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        try assertEveryInputGrows("The Book Information sheet", expected: 2) {
            NavigationStack { PhoneBookInfoSheet(book: book, library: library, info: .simple) }
        }
    }

    // MARK: - The Canary

    /// SwiftUI's own UIKit text inputs still have the switch off. A GitHub run
    /// (November 16, 2026, iOS 26.0.1) found `adjustsFontForContentSizeCategory`
    /// false, in the body text style, on a bare field, one with `selection:`, a
    /// number-pad field, and a multi-line one (a UITextView): the cause of the
    /// audit's finding. When a later iOS turns it on, this fails: the finding
    /// is gone from the audit, and `Accepted.swiftUITextField` and its uses can
    /// go with it.
    func testSwiftUIStillLeavesTheDynamicTypeSwitchOff() throws {
        struct Plain: View {
            @State var text = "47.0"
            @State var selection: TextSelection?
            var body: some View {
                Form {
                    TextField("", text: $text, selection: $selection).keyboardType(.numbersAndPunctuation)
                    TextField("", text: $text).keyboardType(.numberPad)
                    TextField("", text: $text, axis: .vertical).lineLimit(1...6)
                }
            }
        }
        let inputs = textInputs(in: try host(Plain()).view)
        XCTAssertEqual(inputs.count, 3, "The plain form has \(inputs.count) text inputs, expected 3")
        let switchedOn = inputs.enumerated().filter { adjusts($0.element) }.map { "input \($0.offset)" }
        XCTAssertEqual(
            switchedOn, [],
            "SwiftUI now turns adjustsFontForContentSizeCategory on for \(switchedOn.joined(separator: ", ")): the audit's finding should be gone, so remove Accepted.swiftUITextField, its uses, and this canary"
        )
    }
}
