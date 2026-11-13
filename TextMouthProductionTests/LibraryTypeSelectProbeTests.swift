import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// What letter navigation does in the Library list and in SwiftUI lists on
/// this macOS, found by typing into hosted lists, for the leading-articles
/// design (TITLE-ARTICLES-RESEARCH-2026-11-13.md): which string a typed
/// letter matches, where AppKit's search starts, when typed letters stop
/// adding up and whether that time follows a system setting, whether
/// `onKeyPress` takes a letter before AppKit's type select does, and
/// whether a list scrolls to a row selected in code or typed to.
///
/// Each finding is printed on a line beginning `TYPE-SELECT-PROBE:`, so the
/// run's log holds them. The tests assert only what must hold for the probe
/// to mean anything (a list was drawn, its table took the keyboard), never a
/// finding, so a finding can't fail a train.
///
/// Every key typed matches some row whichever way AppKit matches, and every
/// key goes to a table that has the keyboard, since a key nobody takes makes
/// the Mac beep and no test may make a sound. Even so, a key AppKit turned
/// down would beep, so the probe runs only on GitHub's runner, which has no
/// sound and sets `TEXTMOUTH_TEST_TIME_SCALE`; on this Mac it skips.
///
/// **It runs only on request.** The probe's findings are settled (the leading
/// articles design holds them, and `LibraryTypeSelectBehaviorTests` asserts
/// the ones that can be asserted), and it costs about 72 seconds of a runner
/// run, so no train or suite runs it: it skips unless the test host has
/// `TEXTMOUTH_TYPE_SELECT_PROBE` set as well. To run it, send a request by
/// hand (as `github_run.run_remotely` takes it) with
/// `"classes": ["LibraryTypeSelectProbeTests"]` and
/// `"type_select_probe": true`, which `run-on-runner.py` hands to the test
/// host as that variable; read the `TYPE-SELECT-PROBE:` lines of the run's
/// `run.log`. Its timing test writes `InitialKeyRepeat` and
/// `com.apple.mouse.doubleClickThreshold` into the app's own defaults
/// domain, which is safe only on a fresh runner.
@MainActor
final class LibraryTypeSelectProbeTests: XCTestCase {

    /// Skips the probe anywhere but GitHub's runner, and there unless the
    /// request asked for it (see the class).
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        guard environment["TEXTMOUTH_TEST_TIME_SCALE"] != nil else {
            throw XCTSkip("The type-select probe types into lists, which can beep, so it runs on GitHub's runner only")
        }
        guard environment["TEXTMOUTH_TYPE_SELECT_PROBE"] != nil else {
            throw XCTSkip("The type-select probe runs only on request: its request says type_select_probe")
        }
    }

    // MARK: - The Library List

    /// The Library list as main draws it: its table, the type-select strings
    /// its delegate gives each row, what typing a letter selects, where a
    /// search starts, and when typed letters start a new search.
    func testWhatTypingDoesInTheLibraryList() throws {
        let titles = [
            "Apple Pie", "Banana Republic", "Avocado Toast", "The Hobbit", "Treasure Island",
            "Hamlet", "Robinson Crusoe", "A Tale of Two Cities",
        ]
        let folder = "Probe"
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: titles.enumerated().map { index, title in
                Book(
                    title: title,
                    author: "Author \(index)",
                    format: .epub,
                    filePath: "/nonexistent/type-select-probe/\(index).epub",
                    md5Hash: "type-select-probe-\(index)",
                    folderPath: folder,
                    manualSortOrder: index
                )
            },
            folders: [BookFolder(name: folder)]
        )
        let location = LibraryLocation(category: .folders, folderPath: folder)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
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
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        report("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        describe(table, named: "Library list")

        // Which row holds which title: the delegate's strings when it gives
        // them; otherwise the books' titles in their order on the last rows,
        // under the Books section's header.
        let given = typeSelectStrings(of: table)
        let strings: [String?]
        if given.contains(where: { $0 != nil }) || table.numberOfRows < titles.count {
            strings = given
        } else {
            let header = table.numberOfRows - titles.count
            strings = Array(repeating: nil, count: header) + titles.map { Optional($0) }
            report("Library list: the delegate gives no strings; rows \(header)... taken for the books in order")
        }
        func titleOfSelectedRow() -> String {
            let row = table.selectedRow
            guard row >= 0 else { return "no row selected" }
            return "row \(row): \(strings.indices.contains(row) ? strings[row] ?? "nil" : "?")"
        }
        func selectRow(holding title: String) -> Bool {
            guard let row = strings.firstIndex(where: { $0?.contains(title) == true }) else {
                report("Library list: no row holds \(title), so its probe was not run")
                return false
            }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            flush(hosted.hostingView)
            return true
        }

        let tookFocus = hosted.window.makeFirstResponder(table)
        report("Library list: makeFirstResponder(table) \(tookFocus); first responder \(describe(hosted.window.firstResponder))")
        guard tookFocus, hosted.window.firstResponder === table else {
            report("Library list: the table did not take the keyboard, so nothing was typed")
            return
        }

        // A letter every way of matching finds: what it selects, from no
        // selection.
        table.deselectAll(nil)
        settle(hosted.hostingView, seconds: 3)
        typeKey("b", into: hosted.window)
        flush(hosted.hostingView)
        report("Library list: typed b with nothing selected: \(titleOfSelectedRow())")

        // Where the search starts: with Banana Republic selected, A finds
        // Apple Pie above it from the top, or Avocado Toast below it from the
        // selection.
        if selectRow(holding: "Banana Republic") {
            settle(hosted.hostingView, seconds: 3)
            typeKey("a", into: hosted.window)
            flush(hosted.hostingView)
            report("Library list: typed a with Banana Republic selected: \(titleOfSelectedRow())")
        }
        // With Avocado Toast selected, A stays there (the selected row is
        // searched first), moves on to A Tale of Two Cities (the search
        // starts after it), or goes back to Apple Pie (from the top).
        if selectRow(holding: "Avocado Toast") {
            settle(hosted.hostingView, seconds: 3)
            typeKey("a", into: hosted.window)
            flush(hosted.hostingView)
            report("Library list: typed a with Avocado Toast selected: \(titleOfSelectedRow())")
        }
        // H: Hamlet when a title must start with the letters, The Hobbit
        // when a word inside it may.
        if selectRow(holding: "Apple Pie") {
            settle(hosted.hostingView, seconds: 3)
            typeKey("h", into: hosted.window)
            flush(hosted.hostingView)
            report("Library list: typed h with Apple Pie selected: \(titleOfSelectedRow())")
        }
        // "the h": does a space join the search, and does it reach The Hobbit?
        if selectRow(holding: "Apple Pie") {
            settle(hosted.hostingView, seconds: 3)
            for character in "the h" {
                typeKey(character, into: hosted.window)
                flush(hosted.hostingView)
                report("Library list: typed \"\(character)\" of \"the h\": \(titleOfSelectedRow())")
            }
        }

        // When typed letters start a new search: T then R is Treasure
        // Island while they add up, Robinson Crusoe once R starts afresh.
        // First with event timestamps far apart but no time between them,
        // then the other way round, to learn which clock AppKit reads.
        if selectRow(holding: "Apple Pie") {
            settle(hosted.hostingView, seconds: 3)
            let start = ProcessInfo.processInfo.systemUptime
            typeKey("t", into: hosted.window, timestamp: start)
            typeKey("r", into: hosted.window, timestamp: start + 10)
            flush(hosted.hostingView)
            report("Library list: t then r, timestamps 10 s apart, no time between: \(titleOfSelectedRow())")
        }
        if selectRow(holding: "Apple Pie") {
            settle(hosted.hostingView, seconds: 3)
            let start = ProcessInfo.processInfo.systemUptime
            typeKey("t", into: hosted.window, timestamp: start)
            settle(hosted.hostingView, seconds: 2.5)
            typeKey("r", into: hosted.window, timestamp: start + 0.1)
            flush(hosted.hostingView)
            report("Library list: t then r, timestamps 0.1 s apart, 2.5 s between: \(titleOfSelectedRow())")
        }
        // The gap at which R starts a new search, the run loop turning
        // meanwhile, with each event stamped when it is sent.
        for gap in [0.3, 0.6, 0.9, 1.2, 1.6, 2.2] {
            guard selectRow(holding: "Apple Pie") else { break }
            settle(hosted.hostingView, seconds: 3)
            typeKey("t", into: hosted.window)
            settle(hosted.hostingView, seconds: gap)
            typeKey("r", into: hosted.window)
            flush(hosted.hostingView)
            report("Library list: t then r \(gap) s apart: \(titleOfSelectedRow())")
        }
        report(
            "keyRepeatDelay \(NSEvent.keyRepeatDelay), keyRepeatInterval \(NSEvent.keyRepeatInterval), "
                + "doubleClickInterval \(NSEvent.doubleClickInterval), InitialKeyRepeat "
                + "\(String(describing: UserDefaults.standard.object(forKey: "InitialKeyRepeat"))), KeyRepeat "
                + "\(String(describing: UserDefaults.standard.object(forKey: "KeyRepeat")))"
        )
        // What the window's search fields hold after the typing.
        let fields = descendants(of: hosted.window.contentView ?? hosted.hostingView, as: NSSearchField.self)
        report("Library list: search fields in the window \(fields.count), holding \(fields.map(\.stringValue))")
    }

    /// Whether AppKit's own type select, which the first choice keeps,
    /// scrolls a row far down the Library list into view whole: T selects
    /// The Zebra, the row before last, in a list of sixty volumes then The
    /// Zebra and Theodora.
    func testWhetherAppKitScrollsFarDownTheLibraryList() throws {
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)
        LeadingArticles.preference.write(.partOfTitle, to: store)
        let folder = "Long Probe"
        let titles = (1...60).map { String(format: "Volume %02d", $0) } + ["The Zebra", "Theodora"]
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: titles.enumerated().map { index, title in
                Book(
                    title: title,
                    author: "Author",
                    format: .epub,
                    filePath: "/nonexistent/type-select-probe-long/\(index).epub",
                    md5Hash: "type-select-probe-long-\(index)",
                    folderPath: folder,
                    manualSortOrder: index
                )
            },
            folders: [BookFolder(name: folder)]
        )
        let location = LibraryLocation(category: .folders, folderPath: folder)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(folder),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings),
            size: NSSize(width: 700, height: 420)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
            return report("Long Library list: the table did not take the keyboard, so nothing was typed")
        }
        typeKey("t", into: hosted.window)
        settle(hosted.hostingView, seconds: 0.5)
        let selected = table.selectedRow
        let visible = table.rows(in: table.visibleRect)
        let whole = selected >= 0 && LibraryTitleTyping.rowShowsWhole(selected, in: table)
        report(
            "Long Library list, first choice: typed t: row \(selected) of \(table.numberOfRows) selected; "
                + "rows \(visible.location)..<\(visible.location + visible.length) show; the row shows whole: \(whole)"
        )
    }

    // MARK: - When Typed Letters Start Afresh

    /// When AppKit's type select starts a new search, in a fresh list for
    /// each try, so no try's letters linger into the next: T then R is
    /// Treasure Island while they add up, Robinson Crusoe once R starts
    /// afresh. First at the runner's own settings, in steps between the 1.2
    /// seconds that added up and the 1.6 that did not (train 1113-0322);
    /// then with a longer key repeat delay, and then a longer double-click
    /// interval, each set only while it is tried, to learn whether the time
    /// follows either setting.
    func testWhenTypedLettersStartANewSearch() throws {
        try tryLettersApart(by: [1.3, 1.4, 1.45, 1.5, 1.55], named: "Interval")
        try withAppSetting("InitialKeyRepeat", 120, read: { NSEvent.keyRepeatDelay }, named: "keyRepeatDelay") { name in
            try tryLettersApart(by: [2.0, 4.0], named: name)
        }
        try withAppSetting("com.apple.mouse.doubleClickThreshold", 2.0, read: { NSEvent.doubleClickInterval }, named: "doubleClickInterval") { name in
            try tryLettersApart(by: [2.0, 4.0], named: name)
        }
    }

    /// Types T, then R each of `gaps` seconds later, into a fresh list of
    /// Apple Pie, Treasure Island, and Robinson Crusoe, printing what each
    /// selects. Both letters reach a row however they are taken, so nothing
    /// beeps. Each try waits longer than the runner's interval first, in
    /// case AppKit keeps one search for all its tables.
    private func tryLettersApart(by gaps: [TimeInterval], named name: String) throws {
        let titles = ["Apple Pie", "Treasure Island", "Robinson Crusoe"]
        for gap in gaps {
            let rows = ProbeRows(titles: titles, equivalents: nil)
            let hosted = hostOffscreen(ProbeList(rows: rows, selection: ProbeSelection(), usesEquivalents: false))
            defer { takeDown(hosted.window) }
            settle(hosted.hostingView, seconds: 1.7)
            let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "no list drawn")
            guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
                return report("\(name): the table did not take the keyboard, so nothing was typed")
            }
            /// The title of the row selected, for the report.
            func selectedTitle() -> String {
                titles.indices.contains(table.selectedRow) ? titles[table.selectedRow] : "row \(table.selectedRow)"
            }
            typeKey("t", into: hosted.window)
            settle(hosted.hostingView, seconds: gap)
            let afterT = selectedTitle()
            typeKey("r", into: hosted.window)
            flush(hosted.hostingView)
            report("\(name): t then r \(gap) s apart: \(afterT), then \(selectedTitle())")
        }
    }

    /// Runs `body` with `key` set to `value` in this app's own domain,
    /// which AppKit reads before the system's, and then takes it away: only
    /// when no domain holds the key already, as on GitHub's fresh runner,
    /// so a setting someone made is never touched, and only once `read`,
    /// AppKit's reading of the setting, shows the new value. `body` is
    /// given a name for its findings that carries that value.
    private func withAppSetting(
        _ key: String,
        _ value: Any,
        read: () -> TimeInterval,
        named name: String,
        _ body: (String) throws -> Void
    ) rethrows {
        guard UserDefaults.standard.object(forKey: key) == nil else {
            return report("\(name): \(key) is set already, so it was left alone and not tried")
        }
        let before = read()
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let after = read()
        report("\(name): \(before) with \(key) unset, \(after) with it \(value)")
        guard after != before else {
            return report("\(name): AppKit kept its reading, so nothing was typed")
        }
        try body("\(name) \(after)")
    }

    // MARK: - SwiftUI Lists

    /// A SwiftUI list whose rows name their own type-select strings
    /// (`typeSelectEquivalent(_:)`): what its delegate gives each row, and
    /// whether typing follows those strings rather than the rows' text.
    func testATypeSelectEquivalentIsWhatTypingMatches() throws {
        let rows = ProbeRows(titles: ["The Hobbit", "Apple Pie", "Zebra Crossing"], equivalents: ["Hobbit, The", "Apple Pie", "Zebra Crossing"])
        let selection = ProbeSelection()
        let hosted = hostOffscreen(ProbeList(rows: rows, selection: selection, usesEquivalents: true))
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "no list drawn")
        describe(table, named: "List with equivalents")
        _ = typeSelectStrings(of: table)
        guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
            report("List with equivalents: the table did not take the keyboard, so nothing was typed")
            return
        }
        // H matches only the equivalent "Hobbit, The"; the row shows "The Hobbit".
        typeKey("h", into: hosted.window)
        settle(hosted.hostingView, seconds: 0.2)
        report("List with equivalents: typed h: selected \(rows.title(of: selection.ids)), table row \(table.selectedRow)")
    }

    /// A SwiftUI list with `onKeyPress`: whether the handler sees a letter
    /// before AppKit's type select, and what happens to the selection when
    /// it takes the letter and when it passes it on.
    func testOnKeyPressOnAListSeesLettersFirst() throws {
        for takesTheKey in [true, false] {
            let rows = ProbeRows(titles: ["Apple Pie", "Banana Republic", "Zebra Crossing"], equivalents: nil)
            let selection = ProbeSelection()
            let presses = ProbePresses()
            let hosted = hostOffscreen(ProbeList(rows: rows, selection: selection, usesEquivalents: false) { press in
                presses.seen.append("\(press.characters)|\(press.modifiers.rawValue)|\(press.phase)")
                return takesTheKey ? .handled : .ignored
            })
            defer { takeDown(hosted.window) }
            settle(hosted.hostingView, seconds: 0.5)
            let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "no list drawn")
            guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
                report("onKeyPress (\(takesTheKey ? "handled" : "ignored")): the table did not take the keyboard")
                continue
            }
            // Z matches Zebra Crossing however AppKit matches, so nothing beeps.
            typeKey("z", into: hosted.window)
            settle(hosted.hostingView, seconds: 0.2)
            report(
                "onKeyPress (\(takesTheKey ? "handled" : "ignored")): handler saw \(presses.seen); "
                    + "selected \(rows.title(of: selection.ids)), table row \(table.selectedRow)"
            )
        }
    }

    /// A long SwiftUI list: whether a row selected in code is scrolled into
    /// view by itself, and after `ScrollViewReader`'s `scrollTo`.
    func testARowSelectedInCodeIsScrolledIntoView() throws {
        let rows = ProbeRows(titles: (0..<200).map { "Row \($0)" }, equivalents: nil)
        let selection = ProbeSelection()
        let hosted = hostOffscreen(ProbeList(rows: rows, selection: selection, usesEquivalents: false), size: NSSize(width: 500, height: 300))
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "no list drawn")
        let target = 150
        selection.ids = [rows.ids[target]]
        settle(hosted.hostingView, seconds: 0.3)
        let visibleBefore = table.rows(in: table.visibleRect)
        report("Scrolling: selected row \(table.selectedRow) in code; visible rows \(visibleBefore.location)..<\(visibleBefore.location + visibleBefore.length)")
        selection.scrollTarget = rows.ids[target]
        settle(hosted.hostingView, seconds: 0.5)
        let visibleAfter = table.rows(in: table.visibleRect)
        report("Scrolling: after scrollTo, visible rows \(visibleAfter.location)..<\(visibleAfter.location + visibleAfter.length)")
    }

    // MARK: - Typing

    /// Types `character` into `window` as the keyboard does, with no
    /// modifier, stamped `timestamp` (now when nil). The window hands it to
    /// its first responder.
    private func typeKey(_ character: Character, into window: NSWindow, timestamp: TimeInterval? = nil) {
        let text = String(character)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: Self.keyCodes[character] ?? 0
        ) else {
            return XCTFail("no key-down event for \(text)")
        }
        window.sendEvent(event)
    }

    /// The ANSI virtual key codes of the keys the probe types.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "h": 4, "z": 6, "b": 11, "e": 14, "r": 15, "t": 17, " ": 49,
    ]

    // MARK: - Reading the Table

    /// Prints what `table` is and what its delegate offers type select.
    private func describe(_ table: NSTableView, named name: String) {
        var classes: [String] = []
        var lineage: AnyClass? = object_getClass(table)
        while let current = lineage, classes.count < 8 {
            classes.append(NSStringFromClass(current))
            lineage = class_getSuperclass(current)
        }
        report("\(name): table classes \(classes)")
        report("\(name): allowsTypeSelect \(table.allowsTypeSelect), rows \(table.numberOfRows), columns \(table.numberOfColumns)")
        let delegate = table.delegate
        report("\(name): delegate \(describe(delegate)), data source \(describe(table.dataSource))")
        let selectors: [(String, Selector)] = [
            ("typeSelectStringFor", #selector(NSTableViewDelegate.tableView(_:typeSelectStringFor:row:))),
            ("nextTypeSelectMatchFromRow", #selector(NSTableViewDelegate.tableView(_:nextTypeSelectMatchFromRow:toRow:for:))),
            ("shouldTypeSelectFor", #selector(NSTableViewDelegate.tableView(_:shouldTypeSelectFor:withCurrentSearch:))),
        ]
        for (label, selector) in selectors {
            report("\(name): delegate responds to \(label): \(delegate?.responds(to: selector) ?? false)")
        }
    }

    /// The type-select string the delegate gives each row of `table`, in
    /// row order (nil where it gives none or doesn't say), printed.
    private func typeSelectStrings(of table: NSTableView) -> [String?] {
        let column = table.tableColumns.first
        let strings: [String?] = (0..<table.numberOfRows).map { row in
            table.delegate?.tableView?(table, typeSelectStringFor: column, row: row)
        }
        for (row, string) in strings.enumerated() {
            report("row \(row) type-select string: \(string.map { "\"\($0)\"" } ?? "nil")")
        }
        return strings
    }

    /// What an object is, for the report.
    private func describe(_ object: AnyObject?) -> String {
        object.map { NSStringFromClass(Swift.type(of: $0)) } ?? "nil"
    }

    /// Prints one finding where the run's log keeps it.
    private func report(_ finding: String) {
        print("TYPE-SELECT-PROBE: \(finding)")
    }
}

// MARK: - The Probe's Lists

/// One row of a probe list: its identity, its title, and the type-select
/// equivalent it names when its list names them.
private struct ProbeRow: Identifiable {
    let id = UUID()
    let title: String
    let equivalent: String?
}

/// The rows of a probe list, in order.
private struct ProbeRows {
    let rows: [ProbeRow]

    /// Rows titled `titles`, each with the equivalent at its index in
    /// `equivalents`, when given.
    init(titles: [String], equivalents: [String]?) {
        rows = titles.enumerated().map { index, title in
            ProbeRow(title: title, equivalent: equivalents.flatMap { $0.indices.contains(index) ? $0[index] : nil })
        }
    }

    /// The rows' identities, in order.
    var ids: [UUID] { rows.map(\.id) }

    /// The titles of the rows `selected` names, for the report.
    func title(of selected: Set<UUID>) -> String {
        let names = rows.filter { selected.contains($0.id) }.map(\.title)
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }
}

/// A probe list's selection and the row it is asked to scroll to.
@MainActor
private final class ProbeSelection: ObservableObject {
    @Published var ids: Set<UUID> = []
    @Published var scrollTarget: UUID?
}

/// The key presses a probe list's handler saw.
@MainActor
private final class ProbePresses {
    var seen: [String] = []
}

/// A SwiftUI list of `rows` with selection, as the Library list is: rows
/// that are `Text`, with their type-select equivalents when asked, a key
/// press handler when given one, and a scroll reader that scrolls to the
/// selection's `scrollTarget`.
private struct ProbeList: View {
    let rows: ProbeRows
    @ObservedObject var selection: ProbeSelection
    let usesEquivalents: Bool
    /// What a key press on the list does, on the main actor, as SwiftUI
    /// calls it; nil for no handler.
    var onKey: (@MainActor (KeyPress) -> KeyPress.Result)?

    var body: some View {
        ScrollViewReader { proxy in
            keyed(list)
                .onChange(of: selection.scrollTarget) { _, target in
                    if let target {
                        proxy.scrollTo(target)
                    }
                }
        }
    }

    /// The list itself.
    private var list: some View {
        List(selection: $selection.ids) {
            ForEach(rows.rows) { row in
                if usesEquivalents, let equivalent = row.equivalent {
                    Text(row.title).typeSelectEquivalent(equivalent)
                } else {
                    Text(row.title)
                }
            }
        }
    }

    /// `content` with the key press handler, when there is one.
    @ViewBuilder
    private func keyed<Content: View>(_ content: Content) -> some View {
        if let onKey {
            content.onKeyPress(phases: .down) { press in onKey(press) }
        } else {
            content
        }
    }
}
