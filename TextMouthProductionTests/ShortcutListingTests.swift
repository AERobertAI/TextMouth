import XCTest
@testable import TextMouth

/// config.json's three forms of an action's entry (FR12, `ShortcutListing`):
/// a list makes the action the user's, an object makes it the user's
/// working in the kind of window it names (FR12's branch E), text beginning
/// with "default" gives it TextMouth's defaults, and any other text is one
/// shortcut. Then how a record of the user's edits is written as entries,
/// how entries are put in place in a record, and how config.json names an
/// action.
@MainActor
final class ShortcutListingTests: XCTestCase {

    // MARK: - Keys Used Below

    private let plainW = KeyBinding(key: "w")
    private let plainK = KeyBinding(key: "k")
    private let shiftR = KeyBinding(key: "r", shift: true)
    private let commandJ = KeyBinding(key: "j", command: true)
    private let space = KeyBinding(key: "space")
    private let shiftCommandT = KeyBinding(key: "t", command: true, shift: true)

    // MARK: - Reading an Entry

    /// A list of shortcuts gives the action those keys, each once, as the
    /// user's, an empty list none; a list holding a shortcut that cannot be
    /// read cannot be used, and leaves the action as it is.
    func testAListIsTheUsersKeys() {
        let listing: ShortcutListing = ["Option + W", "space", "option+w"]

        XCTAssertFalse(listing.followsDefaults)
        XCTAssertEqual(listing.bindings, [KeyBinding(key: "w", option: true), space])
        XCTAssertEqual(listing.validated, ["option+w", "space"])
        XCTAssertEqual(ShortcutListing.list([]).bindings, [])
        XCTAssertEqual(ShortcutListing.list([]).validated, .list([]))
        XCTAssertNil(ShortcutListing.list(["space", "hyper+k"]).bindings)
        XCTAssertNil(ShortcutListing.list(["space", "hyper+k"]).validated)
    }

    /// Text beginning with "default", in any letter case, gives the action
    /// TextMouth's defaults. Its other words are never read, so it is kept
    /// exactly as written.
    func testTextBeginningWithDefaultFollowsTheDefaults() {
        for text in ["default: w", "default", "DEFAULT", "Default: anything at all", "  default: none", "defaults"] {
            let listing = ShortcutListing.text(text)
            XCTAssertTrue(listing.followsDefaults, text)
            XCTAssertNil(listing.bindings, text)
            XCTAssertEqual(listing.validated, listing, text)
        }
    }

    /// Any other text is one shortcut, read as a list of one and written
    /// back as one; text naming no shortcut cannot be used.
    func testOtherTextIsOneShortcut() {
        let text = ShortcutListing.text("Cmd+[")

        XCTAssertFalse(text.followsDefaults)
        XCTAssertEqual(text.bindings, [KeyBinding(key: "[", command: true)])
        XCTAssertEqual(text.validated, ["command+["])
        for unreadable in ["none", "", "hyper+k"] {
            XCTAssertNil(ShortcutListing.text(unreadable).bindings, unreadable)
            XCTAssertNil(ShortcutListing.text(unreadable).validated, unreadable)
        }
    }

    /// An object holds the user's keys and the kind of window they work in
    /// (FR12's branch E): its keys are read as a list's, its kind of window
    /// as `ShortcutScope.named(_:)` reads it, and it is written in the Works
    /// in pop-up's words. One naming no kind of window is a list, working
    /// where its action does by default, as a list and text do; one naming a
    /// kind TextMouth does not know cannot be used. Only the record's forms,
    /// an object and "default", tell a file from the form earlier releases
    /// wrote.
    func testAnObjectIsTheUsersKeysWorkingWhereItSays() {
        let object = ShortcutListing.object(keys: ["Shift+Command+T"], worksIn: "every window")

        XCTAssertFalse(object.followsDefaults)
        XCTAssertEqual(object.bindings, [shiftCommandT])
        XCTAssertEqual(object.scope(for: .newFromText), .app)
        XCTAssertEqual(object.validated, .object(keys: ["shift+command+t"], worksIn: "Every window"))
        XCTAssertEqual(ShortcutListing.edited([shiftCommandT], worksIn: .reader), .object(keys: ["shift+command+t"], worksIn: "Reader windows"))

        let namingNone = ShortcutListing.object(keys: ["shift+command+t"], worksIn: nil)
        XCTAssertEqual(namingNone.scope(for: .newFromText), .library)
        XCTAssertEqual(namingNone.validated, ["shift+command+t"])
        XCTAssertEqual(ShortcutListing.list(["shift+command+t"]).scope(for: .showSleepTimer), .reader)
        XCTAssertEqual(ShortcutListing.text("default").scope(for: .newFromText), .library)

        let unknown = ShortcutListing.object(keys: ["shift+command+t"], worksIn: "kitchen")
        XCTAssertNil(unknown.scope(for: .newFromText))
        XCTAssertNil(unknown.validated)
        XCTAssertNil(ShortcutListing.object(keys: ["hyper+t"], worksIn: "library").validated)

        XCTAssertTrue(object.isInTheRecordsForm)
        XCTAssertTrue(ShortcutListing.text("default: w").isInTheRecordsForm)
        XCTAssertFalse(ShortcutListing.list(["w"]).isInTheRecordsForm)
        XCTAssertFalse(ShortcutListing.text("w").isInTheRecordsForm)
    }

    /// An entry is read as a list of text, as text, or as an object holding
    /// its keys, a list or one text, and, when it names one, where they work,
    /// its field names in any letter case; anything else is unreadable, and
    /// each form is written in its own.
    func testAnEntryIsCodedAsAListTextOrAnObject() throws {
        let json = #"""
        {"a": ["shift+r"], "b": "default: w", "c": [],
         "d": {"keys": ["w"], "worksIn": "library"},
         "e": {"Keys": "w", "Works In": "Reader windows"},
         "f": {"keys": ["w"]},
         "g": {"keys": [], "worksIn": null}}
        """#

        let decoded = try JSONDecoder().decode([String: ShortcutListing].self, from: Data(json.utf8))

        XCTAssertEqual(decoded, [
            "a": ["shift+r"], "b": "default: w", "c": [],
            "d": .object(keys: ["w"], worksIn: "library"),
            "e": .object(keys: ["w"], worksIn: "Reader windows"),
            "f": .object(keys: ["w"], worksIn: nil),
            "g": .object(keys: [], worksIn: nil),
        ])
        let unreadable = ["7", "[7]", "true", #"{"worksIn": "library"}"#, #"{"keys": [7]}"#, #"{"keys": ["w"], "worksIn": 7}"#]
        for entry in unreadable {
            XCTAssertThrowsError(try JSONDecoder().decode(ShortcutListing.self, from: Data(entry.utf8)), entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let written: [String: ShortcutListing] = [
            "a": ["shift+r"], "b": "default: w", "c": [],
            "d": .edited([plainW], worksIn: .library), "f": .object(keys: ["w"], worksIn: nil),
        ]
        XCTAssertEqual(
            String(decoding: try encoder.encode(written), as: UTF8.self),
            #"{"a":["shift+r"],"b":"default: w","c":[],"d":{"keys":["w"],"worksIn":"Library windows"},"f":{"keys":["w"]}}"#
        )
    }

    // MARK: - Writing a Record as Entries

    /// Every action is listed: an edited one as a list of its keys, every
    /// other one as "default: " and its keys in force, or "default: none".
    /// This user's record lists as the design's excerpt of config.json shows.
    func testEveryActionIsListedInOneOfTheTwoForms() {
        let listings = ShortcutEdits([.releaseMediaControls: [shiftR]]).listings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(Set(listings.keys), Set(ShortcutAction.allCases))
        XCTAssertEqual(listings[.addBookmark], "default: command+b")
        XCTAssertEqual(listings[.addToReadingList], "default: none")
        XCTAssertEqual(listings[.nextBookmark], "default: option+shift+command+b")
        XCTAssertEqual(listings[.togglePlayback], "default: space, k")
        XCTAssertEqual(listings[.releaseMediaControls], ["shift+r"])
        XCTAssertEqual(listings[.showBookmarkList], "default: shift+command+b")
        XCTAssertEqual(listings[.speakInfo], "default: i")
        XCTAssertEqual(listings[.whereAmI], "default: w")
        XCTAssertEqual(listings[.editorPlayPause], "default: space, k")
        XCTAssertEqual(ShortcutListing.edited([]), .list([]))
        XCTAssertEqual(ShortcutListing.followingDefaults([space, plainK]), "default: space, k")
    }

    /// An entry lists the keys in force: an action edited back to its
    /// default keys is still a list, and an unedited action's text leaves
    /// out a key an edited action holds.
    func testEntriesListTheKeysInForce() {
        let listings = ShortcutEdits([.whereAmI: [plainW, plainK]]).listings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(listings[.whereAmI], ["w", "k"])
        XCTAssertEqual(listings[.togglePlayback], "default: space")
        XCTAssertEqual(ShortcutEdits([.whereAmI: [plainW]]).listings(defaults: ShortcutAction.defaultBindings)[.whereAmI], ["w"])
    }

    /// An unedited action working in Library or reader windows by default
    /// says so after "default" (FR12's branch E), so the file says why two
    /// actions may have one key; an edited action working in a kind of
    /// window the user chose is an object, and one working where it does by
    /// default a list.
    func testEntriesSayWhereTheirActionsWork() {
        var record = ShortcutEdits([.releaseMediaControls: [shiftR], .showBookmarkList: [KeyBinding(key: "b", command: true, shift: true)]])
        record.setScope(.app, for: .newFromText, keys: [shiftCommandT])
        let listings = record.listings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(listings[.newFromText], .object(keys: ["shift+command+t"], worksIn: "Every window"))
        XCTAssertEqual(listings[.showSleepTimer], "default in reader windows: none", "New from Text has its key in reader windows now")
        XCTAssertEqual(listings[.addFeed], "default in Library windows: shift+command+f")
        XCTAssertEqual(listings[.searchInBook], "default in reader windows: command+f")
        XCTAssertEqual(listings[.openBook], "default: command+o")
        XCTAssertEqual(listings[.editorPlayPause], "default: space, k")
        XCTAssertEqual(listings[.recordingStop], "default: command+.")
        XCTAssertEqual(listings[.releaseMediaControls], ["shift+r"])
        XCTAssertEqual(listings[.showBookmarkList], ["shift+command+b"])
        XCTAssertEqual(ShortcutEdits().listings(defaults: ShortcutAction.defaultBindings)[.newFromText], "default in Library windows: shift+command+t")
        XCTAssertEqual(ShortcutEdits().listings(defaults: ShortcutAction.defaultBindings)[.showSleepTimer], "default in reader windows: shift+command+t")
        XCTAssertEqual(
            ShortcutEdits([.showSleepTimer: [shiftCommandT]]).listings(defaults: ShortcutAction.defaultBindings)[.showSleepTimer],
            ["shift+command+t"],
            "an edited action working where it does by default is a list"
        )
    }

    // MARK: - Putting Entries in Place

    /// A list makes its action the user's; text beginning with "default"
    /// gives an edited action back to the defaults and leaves an unedited
    /// one as it is; other text is one shortcut; an action left out, or
    /// whose entry cannot be read, keeps what it has.
    func testEachFormPutsItsActionInPlace() {
        let controlBracket = KeyBinding(key: "[", control: true)
        let record = ShortcutEdits([.releaseMediaControls: [shiftR], .goBack: [controlBracket], .goForward: []])

        let adopted = record.adopting([
            .whereAmI: ["option+w"],
            .goBack: "default: command+[",
            .goToLibrary: "Cmd+J",
            .togglePlayback: "Default: anything",
            .goForward: ["hyper+k"],
        ])

        XCTAssertEqual(adopted.edits, ShortcutEdits([
            .releaseMediaControls: [shiftR],
            .whereAmI: [KeyBinding(key: "w", option: true)],
            .goToLibrary: [commandJ],
            .goForward: [],
        ]))
        XCTAssertEqual(adopted.sharedKeys, [])
    }

    /// Writing a list makes an action the user's even when its keys are its
    /// default, and writing "default" gives it back.
    func testAListAtTheDefaultIsTheUsersAndDefaultGivesItBack() {
        let edited = ShortcutEdits().adopting([.whereAmI: ["w"]]).edits

        XCTAssertTrue(edited.isEdited(.whereAmI))
        XCTAssertEqual(edited.adopting([.whereAmI: "default"]).edits, ShortcutEdits())
    }

    /// A key two edited actions hold once the entries are in place goes to
    /// the one whose entry changed it, as recording it in Settings would;
    /// when both changed, or neither did, to the one Settings lists first.
    /// The other keeps its other keys and stays edited.
    func testAKeyTwoEditedActionsHoldGoesToTheOneWhoseEntryChanged() {
        let commandL = KeyBinding(key: "l", command: true)
        let record = ShortcutEdits([.goToLibrary: [commandJ], .whereAmI: [plainW]])

        // Only Where Am I?'s entry changed: it takes Command-J.
        let oneChanged = record.adopting([.goToLibrary: ["command+j"], .whereAmI: ["w", "command+j"]])
        XCTAssertEqual(oneChanged.edits, ShortcutEdits([.goToLibrary: [], .whereAmI: [plainW, commandJ]]))
        XCTAssertEqual(oneChanged.sharedKeys, [ShortcutEdits.SharedKey(key: commandJ, keeper: .whereAmI, loser: .goToLibrary)])

        // Both changed: Go to Library, listed first, keeps it.
        let bothChanged = record.adopting([.goToLibrary: ["command+j", "command+l"], .whereAmI: ["w", "command+j"]])
        XCTAssertEqual(bothChanged.edits, ShortcutEdits([.goToLibrary: [commandJ, commandL], .whereAmI: [plainW]]))
        XCTAssertEqual(bothChanged.sharedKeys, [ShortcutEdits.SharedKey(key: commandJ, keeper: .goToLibrary, loser: .whereAmI)])

        // Neither changed, the record holding the key twice already, as a
        // store edited by hand may: Go to Library keeps it.
        let twice = ShortcutEdits([.goToLibrary: [commandJ], .whereAmI: [plainW, commandJ]])
        let neitherChanged = twice.adopting([.goToLibrary: ["command+j"], .whereAmI: ["w", "command+j"]])
        XCTAssertEqual(neitherChanged.edits, ShortcutEdits([.goToLibrary: [commandJ], .whereAmI: [plainW]]))
        XCTAssertEqual(neitherChanged.sharedKeys, [ShortcutEdits.SharedKey(key: commandJ, keeper: .goToLibrary, loser: .whereAmI)])
    }

    /// An object makes its action the user's working where it says, taking
    /// its keys from edited actions whose scopes it now overlaps; a list
    /// then gives it back its default scope, and "default" its keys and its
    /// scope both. An object naming a kind of window its action cannot work
    /// in, or one TextMouth does not know, changes nothing.
    func testAnObjectPutsItsActionInPlaceWhereItSays() {
        let record = ShortcutEdits([.showSleepTimer: [shiftCommandT]])

        let everywhere = record.adopting([.newFromText: .object(keys: ["shift+command+t"], worksIn: "Every window")])
        XCTAssertEqual(everywhere.edits.scope(of: .newFromText), .app)
        XCTAssertEqual(everywhere.edits.keys(of: .newFromText), [shiftCommandT])
        XCTAssertEqual(everywhere.edits.keys(of: .showSleepTimer), [], "its entry changed, so it keeps the key where both now work")
        XCTAssertEqual(everywhere.sharedKeys, [ShortcutEdits.SharedKey(key: shiftCommandT, keeper: .newFromText, loser: .showSleepTimer)])

        let listed = everywhere.edits.adopting([.newFromText: ["shift+command+t"]])
        XCTAssertEqual(listed.edits.scope(of: .newFromText), .library, "a list works where its action does by default")
        XCTAssertTrue(listed.edits.isEdited(.newFromText))
        XCTAssertEqual(everywhere.edits.adopting([.newFromText: "default"]).edits, ShortcutEdits([.showSleepTimer: []]))

        let misplaced: [ShortcutListing] = [
            .object(keys: ["shift+command+f"], worksIn: "reader"),
            .object(keys: ["shift+command+f"], worksIn: "kitchen"),
        ]
        for entry in misplaced {
            XCTAssertEqual(record.adopting([.addFeed: entry]).edits, record, "\(entry)")
        }
    }

    /// The entries a record would not take, each with why: an object naming
    /// a kind of window its action cannot work in, and keys its action
    /// cannot take, unless the record holds them already, as a store edited
    /// by hand may.
    func testTheEntriesARecordLeavesOutSayWhy() {
        let record = ShortcutEdits([.openBook: [plainW]])

        let leftOut = record.entriesLeftOut(of: [
            .addFeed: .object(keys: ["shift+command+f"], worksIn: "reader windows"),
            .searchInBook: ["f"],
            .openBook: ["w"],
            .newFromText: .object(keys: ["shift+command+t"], worksIn: "every window"),
            .whereAmI: "default",
        ])

        XCTAssertEqual(Set(leftOut.keys), [.addFeed, .searchInBook])
        XCTAssertEqual(leftOut[.addFeed], .cannotWorkIn(.reader))
        XCTAssertEqual(leftOut[.addFeed]?.reason, "works in reader windows, which it cannot")
        XCTAssertEqual(
            leftOut[.searchInBook]?.reason,
            #""f" cannot be its shortcut: a menu command's shortcut is one press of a key with Command or Control"#
        )
    }

    /// An unedited action whose key an entry gives another action goes
    /// without it, still unedited, and nothing is reported: it had no entry
    /// of its own to settle.
    func testAKeyAnUneditedActionHadMovesWithoutAReport() {
        let adopted = ShortcutEdits().adopting([.whereAmI: ["k"]])

        XCTAssertEqual(adopted.edits, ShortcutEdits([.whereAmI: [plainK]]))
        XCTAssertEqual(adopted.sharedKeys, [])
        XCTAssertEqual(adopted.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)[.togglePlayback], [space])
    }

    // MARK: - A Round Trip

    /// A record written as entries and read back over an empty record is
    /// the same record, and read back over itself changes nothing.
    func testARecordSurvivesARoundTripThroughItsEntries() throws {
        let record = ShortcutEdits([
            .releaseMediaControls: [shiftR],
            .whereAmI: [plainW, KeyBinding(key: "w", control: true)],
            .goToLibrary: [],
            .editorStop: [KeyBinding(key: "s", shift: true)],
        ])
        let data = try JSONEncoder().encode(record.listings(defaults: ShortcutAction.defaultBindings).keyedByRawValue)
        let entries = try JSONDecoder().decode([String: ShortcutListing].self, from: data)
        let listings = [ShortcutAction: ShortcutListing](keyedByRawValue: entries)

        XCTAssertEqual(listings.count, ShortcutAction.allCases.count)
        XCTAssertEqual(ShortcutEdits().adopting(listings).edits, record)
        XCTAssertEqual(record.adopting(listings).edits, record)
        XCTAssertEqual(record.adopting(listings).sharedKeys, [])
    }

    /// A record whose actions work where the user chose survives the round
    /// trip too (FR12's branch E), and every entry TextMouth writes reads
    /// back as it was written.
    func testARecordOfChosenScopesSurvivesARoundTrip() throws {
        var record = ShortcutEdits([.releaseMediaControls: [shiftR]])
        record.setScope(.app, for: .newFromText, keys: [shiftCommandT])
        record.setScope(.library, for: .whereAmI, keys: [plainW])
        let written = record.listings(defaults: ShortcutAction.defaultBindings)
        let data = try JSONEncoder().encode(written.keyedByRawValue)
        let listings = [ShortcutAction: ShortcutListing](keyedByRawValue: try JSONDecoder().decode([String: ShortcutListing].self, from: data))

        XCTAssertEqual(listings, written)
        XCTAssertEqual(ShortcutEdits().adopting(listings).edits, record)
        XCTAssertEqual(record.adopting(listings).edits, record)
        XCTAssertEqual(record.adopting(listings).sharedKeys, [])
        for (action, entry) in written {
            XCTAssertEqual(entry.validated, entry, action.rawValue)
        }
    }

    // MARK: - Names

    /// config.json may name an action in any letter case, the exact name
    /// tried first; a name naming no action is nil.
    func testActionsAreNamedInAnyLetterCase() {
        XCTAssertEqual(ShortcutAction.named("Where Am I?"), .whereAmI)
        XCTAssertEqual(ShortcutAction.named("where am i?"), .whereAmI)
        XCTAssertEqual(ShortcutAction.named("play / pause"), .togglePlayback)
        XCTAssertEqual(ShortcutAction.named("AUDIO EDITOR: PLAY / PAUSE"), .editorPlayPause)
        XCTAssertNil(ShortcutAction.named("Teleport"))
        XCTAssertNil(ShortcutAction.named("Where Am I"))
        XCTAssertNil(ShortcutAction.named(""))
    }
}
