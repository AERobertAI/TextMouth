import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Settings window shows every control of every tab (TODO A10).
///
/// The window is a fixed size, and until A10 every tab but Text was a form
/// in the columns style, which does not scroll: the Shortcuts tab's controls
/// were nearly eight times the window's height and 223 points wider than
/// it, and Playback, Storage, and Miscellaneous (with its gesture on) were
/// taller than it too, so the controls past the window's edges could be
/// reached by neither the keyboard nor VoiceOver. These tests host each tab
/// at the window's size, as the window draws it, and find every AppKit
/// control in it (pop-up buttons, checkboxes, steppers, sliders, text
/// fields) where the window shows it or where a scroll view scrolls to it.
///
/// Every view is hosted inside a frame of the window's fixed size, as the
/// Settings window holds its tabs. A hosting view sets its window's
/// smallest and largest sizes from its content's, and content whose width
/// follows the width it is given, as the columns-style Shortcuts tab's did
/// (plus 223 points), made a hosting window chase it until AppKit raised an
/// exception, which ends the test host.
@MainActor
final class SettingsTabFitTests: XCTestCase {

    /// The Settings window's size, which every tab is hosted at.
    private let windowSize = NSSize(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)

    // MARK: - The Tabs

    /// The window offers its eleven tabs in the order they have always had
    /// (Braille, added with FMT21, after Text, and Library, added on October
    /// 30, 2026, after Stats), each with a symbol that exists, and only Text
    /// and Library, whose lists scroll by themselves, do not scroll as a
    /// whole.
    func testTheWindowOffersItsElevenTabsInTheirOrder() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["Voice", "Playback", "Shortcuts", "Text", "Braille", "Sounds", "Stats", "Library", "Feeds", "Storage", "Miscellaneous"]
        )
        for tab in SettingsTab.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil), tab.title)
        }
        XCTAssertEqual(SettingsTab.allCases.filter { !$0.scrollsAsAWhole }, [.text, .library])
    }

    // MARK: - Fitting the Window

    /// Each tab measured against the window, without a window, so nothing
    /// can resize one. Its controls, laid out at the window's width without
    /// scrolling, may be taller than the window only if the tab scrolls as
    /// a whole; and the tab as the window draws it, offered the window's
    /// size, takes no more than the window's width. The measures are checked
    /// too: the Shortcuts and Playback tabs are taller than the window, and
    /// the Shortcuts tab drawn as it was before A10 was wider than it.
    func testEveryTabFitsTheWindowOrScrolls() throws {
        let environment = try makeEnvironment()
        let offered = CGSize(width: windowSize.width, height: windowSize.height)
        var heights: [SettingsTab: CGFloat] = [:]
        for tab in SettingsTab.allCases {
            let content = NSHostingView(rootView: environment.apply(to: SettingsTabContent(tab: tab).frame(width: windowSize.width)))
            let height = content.fittingSize.height
            heights[tab] = height
            if height > windowSize.height {
                XCTAssertTrue(
                    tab.scrollsAsAWhole,
                    "\(tab.title) is \(Int(height)) points tall in a window \(Int(windowSize.height)) points tall, and does not scroll"
                )
            }
            let drawn = NSHostingController(rootView: environment.apply(to: SettingsTabPage(tab: tab))).sizeThatFits(in: offered)
            XCTAssertLessThanOrEqual(
                drawn.width,
                windowSize.width + 0.5,
                "\(tab.title) is \(Int(drawn.width)) points wide in a window \(Int(windowSize.width)) points wide"
            )
        }
        XCTAssertGreaterThan(heights[.shortcuts] ?? 0, windowSize.height * 2, "the Shortcuts tab was not measured")
        XCTAssertGreaterThan(heights[.playback] ?? 0, windowSize.height, "the Playback tab was not measured")
        let before = NSHostingController(rootView: environment.apply(to: SettingsTabContent(tab: .shortcuts))).sizeThatFits(in: offered)
        XCTAssertGreaterThan(before.width, windowSize.width, "the columns-style Shortcuts tab was not measured wider than the window")
    }

    /// Every control of every tab, drawn as the window draws it, lies within
    /// the window, or within what a scroll view in the window scrolls to:
    /// the whole height of its document, and its own width, since none of
    /// these scroll sideways.
    func testEveryControlOfEveryTabCanBeReached() throws {
        let environment = try makeEnvironment()
        for tab in SettingsTab.allCases {
            withSettingsPage(environment.apply(to: SettingsTabPage(tab: tab))) { page in
                let controls = visibleControls(in: page)
                XCTAssertFalse(controls.isEmpty, "\(tab.title) drew no controls")
                XCTAssertEqual(
                    controls.filter { !isReachable($0, in: page) }.map { describe($0, in: page) },
                    [],
                    "\(tab.title) has controls the window cannot show; its scroll views hold \(documentHeights(in: page))"
                )
            }
        }
    }

    /// The check above finds clipped controls: the Shortcuts tab drawn as it
    /// was before A10, a columns-style form at the window's size, has
    /// controls above and below the window. (Its buttons, which SwiftUI
    /// draws itself, past the window's sides are not AppKit controls; the
    /// measure of its width finds those.)
    func testTheCheckFindsTheShortcutsTabAsItWasDrawnBeforeA10() throws {
        let environment = try makeEnvironment()
        withSettingsPage(environment.apply(to: SettingsTabContent(tab: .shortcuts))) { page in
            let clipped = visibleControls(in: page).filter { !isReachable($0, in: page) }
            XCTAssertFalse(clipped.isEmpty, "the columns-style Shortcuts tab fit the window")
            // Entirely above or below the window, whichever way the
            // hosting view counts its height.
            XCTAssertTrue(
                clipped.contains {
                    let frame = $0.convert($0.bounds, to: page)
                    return frame.maxY < page.bounds.minY || frame.minY > page.bounds.maxY
                },
                "no control lay wholly past the window's edge: \(clipped.map { describe($0, in: page) })"
            )
        }
    }

    /// The Text tab, which does not scroll as a whole, leaves its rule list
    /// at least a third of the window, with every control around it, the
    /// Repeated Symbols group's among them, within the window.
    func testTheTextTabLeavesItsRuleListRoom() {
        let service = TextSubstitutionService(rules: TextSubstitutionService.defaultRules)
        withSettingsPage(SubstitutionsSettingsView(service: service)) { page in
            let list = descendants(of: page, as: NSTableView.self).first
            XCTAssertNotNil(list, "the rule list was not drawn")
            let listHeight = list?.enclosingScrollView?.frame.height ?? 0
            XCTAssertGreaterThanOrEqual(listHeight, windowSize.height / 3, "the rule list is \(Int(listHeight)) points tall")
            XCTAssertEqual(
                visibleControls(in: page).filter { !isReachable($0, in: page) }.map { describe($0, in: page) },
                []
            )
        }
    }

    /// The Library tab, which does not scroll as a whole, leaves its list of
    /// views at least a third of the window, with every control around it
    /// within the window.
    func testTheLibraryTabLeavesItsListRoom() throws {
        let environment = try makeEnvironment()
        let store = LibraryViewDefinitionStore(preferences: makeSandboxedPreferences("settings-tab-fit-views"))
        withSettingsPage(environment.apply(to: LibraryViewsSettingsView(store: store))) { page in
            let list = descendants(of: page, as: NSTableView.self).first
            XCTAssertNotNil(list, "the list of views was not drawn")
            let listHeight = list?.enclosingScrollView?.frame.height ?? 0
            XCTAssertGreaterThanOrEqual(listHeight, windowSize.height / 3, "the list of views is \(Int(listHeight)) points tall")
            XCTAssertEqual(
                visibleControls(in: page).filter { !isReachable($0, in: page) }.map { describe($0, in: page) },
                []
            )
        }
    }

    // MARK: - Hosting and Measuring

    /// Hosts `view` offscreen in a frame of the window's fixed size, waits
    /// for SwiftUI to draw its AppKit controls, and passes the hosting view
    /// to `body` while the window is alive.
    private func withSettingsPage<Content: View>(_ view: Content, _ body: (NSView) throws -> Void) rethrows {
        let hosted = hostOffscreen(view.frame(width: windowSize.width, height: windowSize.height), size: windowSize)
        defer { takeDown(hosted.window) }
        _ = waitUntil(timeout: 5) {
            hosted.hostingView.layoutSubtreeIfNeeded()
            return !self.visibleControls(in: hosted.hostingView).isEmpty
        }
        // Rows that appear once their data loads are drawn too.
        settle(hosted.hostingView, seconds: 0.2)
        try body(hosted.hostingView)
    }

    /// The AppKit controls SwiftUI drew in `page` that a person could use:
    /// shown, with a size, and not a scroll bar.
    private func visibleControls(in page: NSView) -> [NSControl] {
        descendants(of: page, as: NSControl.self).filter {
            !($0 is NSScroller) && !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 && $0.frame.height > 0
        }
    }

    /// Whether `view` lies where `page` shows it: within its nearest scroll
    /// view's reach, that scroll view lying where `page` shows it, or, with
    /// no scroll view around it, within `page`. A scroll view reaches the
    /// whole height of its document, but only its own width of it unless it
    /// scrolls sideways. Half a point is allowed for rounding.
    private func isReachable(_ view: NSView, in page: NSView) -> Bool {
        let rounding: CGFloat = 0.5
        guard let scrollView = view.enclosingScrollView, scrollView.isDescendant(of: page),
              let document = scrollView.documentView else {
            return page.bounds.insetBy(dx: -rounding, dy: -rounding).contains(view.convert(view.bounds, to: page))
        }
        guard view !== document else { return isReachable(scrollView, in: page) }
        let visible = scrollView.documentVisibleRect
        let reach = NSRect(
            x: scrollView.hasHorizontalScroller ? document.bounds.minX : visible.minX,
            y: document.bounds.minY,
            width: scrollView.hasHorizontalScroller ? document.bounds.width : visible.width,
            height: document.bounds.height
        )
        return reach.insetBy(dx: -rounding, dy: -rounding).contains(view.convert(view.bounds, to: document))
            && isReachable(scrollView, in: page)
    }

    /// `control` as a failure names it: its kind, its label, and where it
    /// lies in `page`.
    private func describe(_ control: NSControl, in page: NSView) -> String {
        "\(type(of: control)) '\(control.accessibilityLabel() ?? "")' at \(control.convert(control.bounds, to: page))"
    }

    /// How tall each scroll view's document is, against the scroll view's
    /// own height, as in "5375 in 508".
    private func documentHeights(in page: NSView) -> [String] {
        descendants(of: page, as: NSScrollView.self).map {
            "\(Int($0.documentView?.frame.height ?? 0)) in \(Int($0.frame.height))"
        }
    }

    // MARK: - Fixtures

    /// The objects the Settings window hands its tabs, each a test's own.
    private struct Environment {
        let settings: SettingsViewModel
        let library: LibraryViewModel
        let shortcuts: KeyboardShortcutManager
        let sounds: SoundEffectService

        /// `content` with every object the Settings scene gives its tabs.
        func apply<Content: View>(to content: Content) -> some View {
            content
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(shortcuts)
                .environmentObject(sounds)
        }
    }

    /// A test's own settings, library, shortcuts, and sounds, with the
    /// tabs' optional controls showing: the smart rewind's pause, the
    /// Bluetooth delay, and the restart gesture's pattern editor.
    private func makeEnvironment() throws -> Environment {
        let settings = try makeIsolatedSettings("settings-tab-fit")
        settings.rewindOnResumeUnit = .sentence
        settings.rewindSmartMode = true
        settings.bluetoothMonitoringEnabled = true
        settings.restartTimerGestureEnabled = true
        settings.restartTimerGesturePattern = "previousTrack,nextTrack,togglePlayPause"
        return Environment(
            settings: settings,
            library: LibraryViewModel(initializeServices: false),
            shortcuts: KeyboardShortcutManager(
                userDefaults: makeSandboxedPreferences("settings-tab-fit-shortcuts"),
                installsEventMonitor: false,
                notificationCenter: NotificationCenter()
            ),
            sounds: SoundEffectService(preferences: makeSandboxedPreferences("settings-tab-fit-sounds"))
        )
    }
}
