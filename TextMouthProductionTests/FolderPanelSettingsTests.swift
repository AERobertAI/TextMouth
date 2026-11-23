import AppKit
import XCTest
@testable import TextMouth

/// The folder choosers' settings as values (the panel is built only where it
/// is presented, so no test starts the system's open-and-save panel service,
/// which takes the keyboard focus), and the one function that applies them to
/// a panel, run here on a recording fake.
@MainActor
final class FolderPanelSettingsTests: XCTestCase {

    // MARK: - A Fake Panel

    /// A stand-in for `NSOpenPanel` that only keeps what it is told. It
    /// starts with values unlike any the settings hold, so a field the
    /// function skips shows as unchanged.
    @MainActor
    private final class RecordingPanel: FolderPanelConfigurable {
        var canChooseDirectories = false
        var canChooseFiles = true
        var allowsMultipleSelection = true
        var canCreateDirectories = true
        var showsHiddenFiles = true
        var treatsFilePackagesAsDirectories = true
        var title: String! = "untouched title"
        var message: String! = "untouched message"
        var prompt: String! = "untouched prompt"
        var directoryURL: URL? = URL(fileURLWithPath: "/untouched")
    }

    // MARK: - Applying

    /// Applying the settings sets every field of the panel.
    func testApplyingSetsEveryField() {
        let settings = FolderPanelSettings(
            canChooseDirectories: true,
            canChooseFiles: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            showsHiddenFiles: false,
            treatsFilePackagesAsDirectories: false,
            title: "A title",
            message: "A message",
            prompt: "A prompt",
            directoryURL: URL(fileURLWithPath: "/Users/reader/Books")
        )
        let panel = RecordingPanel()

        settings.apply(to: panel)

        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertFalse(panel.showsHiddenFiles)
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
        XCTAssertEqual(panel.title, "A title")
        XCTAssertEqual(panel.message, "A message")
        XCTAssertEqual(panel.prompt, "A prompt")
        XCTAssertEqual(panel.directoryURL, URL(fileURLWithPath: "/Users/reader/Books"))
    }

    /// With no starting folder, the panel keeps its own.
    func testNoStartingFolderLeavesThePanelsOwn() {
        let panel = RecordingPanel()

        FolderPanelSettings(title: "T", message: "M", prompt: "P").apply(to: panel)

        XCTAssertEqual(panel.directoryURL, URL(fileURLWithPath: "/untouched"))
    }

    // MARK: - The Export Dialog's Chooser

    /// Export's Choose Folder… picks one folder, never a file, can make a
    /// new one, and starts in the destination shown.
    func testTheExportChooserPicksOneFolderAndStartsInTheDestination() {
        let start = URL(fileURLWithPath: "/Users/reader/Exports")
        let settings = BookExportModel.makeDestinationPanel(startingIn: start)

        XCTAssertTrue(settings.canChooseDirectories)
        XCTAssertFalse(settings.canChooseFiles)
        XCTAssertFalse(settings.allowsMultipleSelection)
        XCTAssertTrue(settings.canCreateDirectories)
        XCTAssertFalse(settings.showsHiddenFiles)
        XCTAssertFalse(settings.treatsFilePackagesAsDirectories)
        XCTAssertEqual(settings.title, "Export To")
        XCTAssertEqual(settings.message, "Choose the folder to export to. New Folder makes one.")
        XCTAssertEqual(settings.prompt, "Choose")
        XCTAssertEqual(settings.directoryURL, start)
    }

    // MARK: - The Compare Libraries Chooser

    /// Compare Libraries' chooser picks one folder, shows hidden ones, makes
    /// no new folder, since both copies are only read, and names its action.
    func testTheCompareChooserPicksOneFolderAndMakesNone() {
        let settings = StorageSettingsView.makeCompareFolderPanel()

        XCTAssertTrue(settings.canChooseDirectories)
        XCTAssertFalse(settings.canChooseFiles)
        XCTAssertFalse(settings.allowsMultipleSelection)
        XCTAssertFalse(settings.canCreateDirectories)
        XCTAssertTrue(settings.showsHiddenFiles)
        XCTAssertFalse(settings.treatsFilePackagesAsDirectories)
        XCTAssertEqual(settings.title, "Choose the Copy to Compare")
        XCTAssertEqual(
            settings.message,
            "Choose the folder that holds another copy of this library. Nothing in it is changed."
        )
        XCTAssertEqual(settings.prompt, "Compare")
    }
}
