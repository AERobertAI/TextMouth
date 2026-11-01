import AppKit
import XCTest
@testable import TextMouth

/// Where the next book opens (0.2.5): the rule as a pure type, the
/// feed's or folder's own choice as data, the global setting and its
/// config.json mirror, and the words of the controls.
@MainActor
final class NextBookWindowTests: XCTestCase {

    // MARK: - The Choice in Force

    /// With no options, as for the reading list, the global setting decides.
    func testWithNoOptionsTheGlobalSettingDecides() {
        for global in NextBookWindow.allCases {
            XCTAssertEqual(
                NextBookWindowRule.choice(options: nil, global: global, globalEndOfBook: .continueNext),
                global
            )
        }
    }

    /// A feed's or folder's own choice wins while its items go on; with no
    /// choice of its own, the global setting does.
    func testTheOwnChoiceWinsWhileItemsGoOn() {
        for global in NextBookWindow.allCases {
            for own in NextBookWindow.allCases {
                let options = ListeningOptions(continuation: .playBookBelow, nextBookWindow: own)
                XCTAssertEqual(
                    NextBookWindowRule.choice(options: options, global: global, globalEndOfBook: .stop),
                    own
                )
            }
            let noChoice = ListeningOptions(continuation: .playBookAbove)
            XCTAssertEqual(
                NextBookWindowRule.choice(options: noChoice, global: global, globalEndOfBook: .stop),
                global
            )
        }
    }

    /// A choice that is dimmed, because the items do not go on, is not in
    /// effect: the global setting decides. "Use the global setting" goes on
    /// only while the global "When book ends" is Continue to Next Book.
    func testADimmedChoiceIsNotInEffect() {
        let stopped = ListeningOptions(continuation: .stop, nextBookWindow: .newWindow)
        XCTAssertEqual(
            NextBookWindowRule.choice(options: stopped, global: .thisWindow, globalEndOfBook: .continueNext),
            .thisWindow
        )
        let followsGlobal = ListeningOptions(nextBookWindow: .newWindow)
        XCTAssertEqual(
            NextBookWindowRule.choice(options: followsGlobal, global: .thisWindow, globalEndOfBook: .stop),
            .thisWindow,
            "the global behavior stops, so the choice is dimmed"
        )
        XCTAssertEqual(
            NextBookWindowRule.choice(options: followsGlobal, global: .thisWindow, globalEndOfBook: .continueNext),
            .newWindow
        )
    }

    /// The control is available exactly while the items go on
    /// (`ListeningOptions.goesOn(under:)`).
    func testTheChoiceIsAvailableWhileItemsGoOn() {
        for behavior in EndOfBookBehavior.allCases {
            for continuation in ListeningOptions.continuationChoices {
                let options = ListeningOptions(continuation: continuation)
                XCTAssertEqual(
                    NextBookWindowRule.choiceIsAvailable(options: options, globalEndOfBook: behavior),
                    options.goesOn(under: behavior)
                )
            }
        }
    }

    // MARK: - The Action

    /// Every arrangement of the choice, the busy states, and the open
    /// window gives its one action.
    func testEveryArrangementGivesItsAction() {
        for choice in NextBookWindow.allCases {
            for busy in [false, true] {
                for canSwitch in [false, true] {
                    for openElsewhere in [false, true] {
                        let action = NextBookWindowRule.action(
                            choice: choice, isBusy: busy, canSwitch: canSwitch, nextBookIsOpenElsewhere: openElsewhere
                        )
                        let label = "\(choice) busy=\(busy) canSwitch=\(canSwitch) open=\(openElsewhere)"
                        if choice == .newWindow || busy || !canSwitch {
                            XCTAssertEqual(action, .openANewWindow, label)
                        } else if openElsewhere {
                            XCTAssertEqual(action, .bringTheOpenWindowForwardThenClose, label)
                        } else {
                            XCTAssertEqual(action, .switchThisWindow, label)
                        }
                    }
                }
            }
        }
    }

    // MARK: - The Choice as Data

    /// The new key round trips, standard options stay standard, and a
    /// choice makes the options non-standard.
    func testTheChoiceRoundTripsAndStandardOptionsAreStillStandard() throws {
        for choice in NextBookWindow.allCases {
            let options = ListeningOptions(nextBookWindow: choice)
            XCTAssertFalse(options.isStandard)
            let data = try JSONEncoder().encode(options)
            XCTAssertEqual(try JSONDecoder().decode(ListeningOptions.self, from: data), options)
        }
        XCTAssertTrue(ListeningOptions().isStandard)
        XCTAssertNil(ListeningOptions.standard.nextBookWindow)
    }

    /// A missing key, an unknown name, or a value of the wrong type reads
    /// as nil, and the other keys are kept.
    func testAMissingOrWrongChoiceReadsAsNil() throws {
        for json in [
            #"{"continuation":"stop"}"#,
            #"{"continuation":"stop","nextBookWindow":"A Window Sideways"}"#,
            #"{"continuation":"stop","nextBookWindow":7}"#,
            #"{"continuation":"stop","nextBookWindow":null}"#,
        ] {
            let options = try JSONDecoder().decode(ListeningOptions.self, from: Data(json.utf8))
            XCTAssertNil(options.nextBookWindow, json)
            XCTAssertEqual(options.continuation, .stop, json)
        }
    }

    /// A record as 0.2.4 writes it, with no such key, still reads, and the
    /// choice then is nil.
    func testARecordFromBeforeTheChoiceStillReads() throws {
        let older = #"{"continuation":"playBookAbove","skipsFinished":false,"predownloadsNext":true}"#
        let options = try JSONDecoder().decode(ListeningOptions.self, from: Data(older.utf8))
        XCTAssertEqual(options, ListeningOptions(continuation: .playBookAbove, skipsFinished: false))
    }

    // MARK: - The Global Setting

    /// The setting is This Window until it is changed, and the choice is
    /// kept in the model's own preferences.
    func testTheGlobalSettingIsThisWindowByDefault() throws {
        let settings = try makeIsolatedSettings("next-book-window-default")
        XCTAssertEqual(settings.nextBookWindow, .thisWindow)
        settings.nextBookWindow = .newWindow
        XCTAssertEqual(settings.nextBookWindow, .newWindow)
        XCTAssertEqual(SettingsPolicy.nextBookWindow.defaultValue, .thisWindow)
        // A stored name that names no choice reads as the default.
        settings.nextBookWindowRaw = "Elsewhere"
        XCTAssertEqual(settings.nextBookWindow, .thisWindow)
    }

    /// config.json names the setting, mirrors it, and receives its change.
    func testConfigJSONCarriesTheSetting() throws {
        let file = try makeConfigFileURL()
        let settings = try makeIsolatedSettings("next-book-window-config", configFile: file)

        let named = try JSONDecoder().decode(
            ConfigService.AppConfig.self, from: Data(#"{"nextBookWindow": "A New Window"}"#.utf8)
        )
        XCTAssertEqual(named.nextBookWindow, "A New Window")
        let unknown = try JSONDecoder().decode(
            ConfigService.AppConfig.self, from: Data(#"{"nextBookWindow": "Nowhere"}"#.utf8)
        )
        XCTAssertEqual(unknown.nextBookWindow, "", "an unsupported name keeps the current choice")
        XCTAssertTrue(ConfigService.AppConfig.Portability.mirrored.contains {
            $0.storeKey == "nextBookWindow" && $0.field == "nextBookWindow"
        })

        settings.nextBookWindow = .newWindow
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                guard let data = try? Data(contentsOf: file),
                      let config = try? ConfigService.decode(data) else { return false }
                return config.nextBookWindow == NextBookWindow.newWindow.rawValue
            },
            "config.json never held nextBookWindow = A New Window"
        )
    }

    /// Settings' pop-up button speaks its label, the chosen window as its
    /// value, and its hint. (Hosted accessibility skips on a Mac that does
    /// not expose it to tests; the words themselves are pinned below.)
    func testThePopUpSpeaksItsLabelValueAndHint() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let settings = try makeIsolatedSettings("next-book-window-popup")
        withHostedView(
            PlaybackSettingsView().environmentObject(settings),
            size: NSSize(width: 600, height: 2400),
            until: { hosting in
                accessibleControls(in: hosting).contains { $0.label == NextBookWindowWording.globalLabel }
            }
        ) { hosting in
            let found = accessibleControls(in: hosting).filter {
                $0.role == .popUpButton && $0.label == NextBookWindowWording.globalLabel
            }
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first?.element.accessibilityValue() as? String, "This Window")
            XCTAssertEqual(found.first?.hint, NextBookWindowWording.globalHint)
        }
    }

    /// What Next in Folder and Previous in Folder say when nothing lies that
    /// way, and when an episode is downloaded first.
    func testTheFolderCommandsWords() {
        XCTAssertEqual(
            FolderNavigationWording.nothingThatWay(EndOfBookWording.noMoreBooksInFolderNote),
            "No more books in folder."
        )
        XCTAssertEqual(
            FolderNavigationWording.nothingThatWay(EndOfBookWording.onlyFinishedBooksInFolderNote(going: .up)),
            "Every book before it in the folder is finished."
        )
        let episode = FeedItem(
            id: "guid:e",
            title: "Part Two",
            firstSeen: Date(timeIntervalSince1970: 0),
            enclosure: FeedEnclosure(url: URL(fileURLWithPath: "/part-two.m4a"), mimeType: "audio/mp4")
        )
        let article = FeedItem(id: "guid:a", title: "Night Trams", firstSeen: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(FolderNavigationWording.downloading(episode, going: .down), "Downloading the next episode: Part Two")
        XCTAssertEqual(FolderNavigationWording.downloading(episode, going: .up), "Downloading the previous episode: Part Two")
        XCTAssertEqual(FolderNavigationWording.downloading(article, going: .down), "Downloading the next article: Night Trams")
    }

    // MARK: - The Words

    /// Every string of the controls, word for word.
    func testTheWords() {
        XCTAssertEqual(NextBookWindow.thisWindow.rawValue, "This Window")
        XCTAssertEqual(NextBookWindow.newWindow.rawValue, "A New Window")
        XCTAssertEqual(NextBookWindowWording.globalLabel, "Open the next book in")
        XCTAssertEqual(
            NextBookWindowWording.globalHint,
            "Where the next book opens when listening goes on from one book to another: "
                + "in this window in place of the book here, or in a new window. "
                + "A book already open in another window is brought forward."
        )
        XCTAssertEqual(NextBookWindowWording.label(.book), "Open the next book in")
        XCTAssertEqual(NextBookWindowWording.label(.episode), "Open the next episode in")
        XCTAssertEqual(NextBookWindowWording.title(nil, global: .newWindow), "Use the global setting (A New Window)")
        XCTAssertEqual(NextBookWindowWording.title(.thisWindow, global: .newWindow), "This Window")
        XCTAssertEqual(NextBookWindowWording.title(.newWindow, global: .thisWindow), "A New Window")
        XCTAssertEqual(
            NextBookWindowWording.hint(.episode, enabled: true),
            "Where the next episode opens when listening goes on from one of this feed's episodes: "
                + "in this window, in a new window, or as the global setting says"
        )
        XCTAssertEqual(
            NextBookWindowWording.hint(.book, enabled: true),
            "Where the next book opens when listening goes on from one of this folder's books: "
                + "in this window, in a new window, or as the global setting says"
        )
        XCTAssertEqual(
            NextBookWindowWording.hint(.episode, enabled: false),
            "Available only while this feed's episodes go on to another episode when one ends"
        )
        XCTAssertEqual(
            NextBookWindowWording.hint(.book, enabled: false),
            "Available only while this folder's books go on to another book when one ends"
        )
    }
}
