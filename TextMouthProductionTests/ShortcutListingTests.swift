import XCTest
@testable import TextMouth

/// config.json's two forms of an action's entry (FR12, `ShortcutListing`):
/// a list makes the action the user's, text beginning with "default" gives
/// it TextMouth's defaults, and any other text is one shortcut. Then how a
/// record of the user's edits is written as entries, how entries are put in
/// place in a record, and how config.json names an action.
@MainActor
final class ShortcutListingTests: XCTestCase {

    // MARK: - Keys Used Below

    private let plainW = KeyBinding(key: "w")
    private let plainK = KeyBinding(key: "k")
    private let shiftR = KeyBinding(key: "r", shift: true)
    private let commandJ = KeyBinding(key: "j", command: true)
    private let space = KeyBinding(key: "space")

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

    /// An entry is read as a list of text or as text, anything else being
    /// unreadable, and written in its own form.
    func testAnEntryIsCodedAsAListOrAsText() throws {
        let json = #"{"a": ["shift+r"], "b": "default: w", "c": []}"#

        let decoded = try JSONDecoder().decode([String: ShortcutListing].self, from: Data(json.utf8))

        XCTAssertEqual(decoded, ["a": ["shift+r"], "b": "default: w", "c": []])
        for unreadable in ["7", #"{"keys": ["w"]}"#, "[7]", "true"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ShortcutListing.self, from: Data(unreadable.utf8)), unreadable)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), #"{"a":["shift+r"],"b":"default: w","c":[]}"#)
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
