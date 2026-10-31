import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Storage settings choose any folder for the library (FR02): the chooser
/// shows hidden folders, makes new ones, and names its action; while the
/// library isn't available it offers another library or the default
/// location instead, and stays available; a move under way shows its
/// progress and Cancel in the status line's place.
@MainActor
final class StorageDestinationSettingsTests: XCTestCase {

    // MARK: - The Folder Chooser

    /// The chooser picks one folder, never a file, shows hidden folders,
    /// can make a new one, and its button names the action.
    func testTheChooserShowsHiddenFoldersMakesNewOnesAndNamesItsAction() {
        let panel = StorageSettingsView.makeLibraryFolderPanel(isLibraryAvailable: true)

        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.showsHiddenFiles)
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
        XCTAssertEqual(panel.prompt, "Choose Location")
        XCTAssertEqual(panel.title, "Choose a Location for the Library")
        XCTAssertEqual(
            panel.message,
            "Choose an empty folder to move the library into, or a folder that holds a TextMouth library to use it. "
                + "You can make a new folder here."
        )
    }

    /// While the library isn't available, the chooser looks for a library
    /// to use instead.
    func testWhileTheLibraryIsNotAvailableTheChooserLooksForALibrary() {
        let panel = StorageSettingsView.makeLibraryFolderPanel(isLibraryAvailable: false)

        XCTAssertTrue(panel.showsHiddenFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertEqual(panel.prompt, "Choose Library")
        XCTAssertEqual(panel.title, "Choose Another Library")
        XCTAssertEqual(panel.message, "Choose a folder that holds a TextMouth library to use it instead.")
    }

    // MARK: - The Buttons

    /// The location buttons say what they do, in both states, to VoiceOver
    /// and on screen.
    func testTheLocationButtonsSayWhatTheyDo() {
        XCTAssertEqual(StorageLocationWording.chooserTitle(isLibraryAvailable: true), "Change Location...")
        XCTAssertEqual(StorageLocationWording.chooserLabel(isLibraryAvailable: true), "Choose a new location for the library")
        XCTAssertEqual(
            StorageLocationWording.chooserHint(isLibraryAvailable: true),
            "Opens a folder chooser. An empty folder receives a copy of the library; "
                + "a folder that holds a TextMouth library can be used as it is."
        )
        XCTAssertEqual(StorageLocationWording.chooserTitle(isLibraryAvailable: false), "Choose Another Library...")
        XCTAssertEqual(StorageLocationWording.chooserLabel(isLibraryAvailable: false), "Choose another library")
        XCTAssertEqual(
            StorageLocationWording.chooserHint(isLibraryAvailable: false),
            "Opens a folder chooser to pick a folder that holds a TextMouth library, which TextMouth then opens instead."
        )
        XCTAssertEqual(StorageLocationWording.useDefaultTitle, "Use Default Location...")
        XCTAssertEqual(StorageLocationWording.useDefaultLabel, "Use the default location")
        XCTAssertEqual(
            StorageLocationWording.useDefaultHint,
            "Opens the library in the default location, ~/.TextMouth, or starts a new one there, "
                + "instead of the library that isn't available."
        )
    }

    /// Choosing another library stays available while the library isn't,
    /// which is the way out when its drive is gone for good; moving and
    /// rebuilding do not. Both wait while the index is recovered or an
    /// operation runs.
    func testChoosingAnotherLibraryStaysAvailableWhileTheLibraryIsNot() {
        XCTAssertFalse(StorageSettingsView.chooserUnavailable(isRecoveringIndex: false, isRunning: false))
        XCTAssertTrue(StorageSettingsView.maintenanceUnavailable(isRecoveringIndex: false, isRunning: false, isLibraryUnavailable: true))
        XCTAssertTrue(StorageSettingsView.chooserUnavailable(isRecoveringIndex: true, isRunning: false))
        XCTAssertTrue(StorageSettingsView.chooserUnavailable(isRecoveringIndex: false, isRunning: true))
    }

    /// While a chosen folder is looked at, and while TextMouth switches to
    /// another library, the status line says so.
    func testTheStatusWhileAFolderIsCheckedAndWhileSwitching() {
        let folder = URL(fileURLWithPath: "/Volumes/Backup/TextMouth")

        XCTAssertEqual(StorageStatus.checking(folder), StorageStatus(message: "Checking /Volumes/Backup/TextMouth...", isFailure: false))
        XCTAssertEqual(
            StorageStatus.running(.useLibrary(at: folder)),
            StorageStatus(message: "Switching to the library in /Volumes/Backup/TextMouth...", isFailure: false)
        )
    }

    // MARK: - A Move Under Way

    /// While the library moves, Storage settings show its progress bar at
    /// the percentage copied in the status line's place.
    func testStorageSettingsShowTheProgressOfAMoveUnderWay() {
        let view = makeStorageSettingsShowingAMove(copiedPercent: 60)

        withHostedView(view, size: NSSize(width: 600, height: 1000), until: { !self.moveBars(in: $0).isEmpty }) { hosting in
            guard let bar = moveBars(in: hosting).first else {
                return XCTFail("Storage settings drew no progress bar for the move")
            }
            XCTAssertEqual(bar.doubleValue / bar.maxValue, 0.6, accuracy: 0.0001)
        }
    }

    /// While the library moves, the move's Cancel is among Storage
    /// settings' labelled buttons, with Change Location, where SwiftUI
    /// exposes them.
    func testStorageSettingsLabelTheMovesCancel() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let view = makeStorageSettingsShowingAMove(copiedPercent: 60)

        try withHostedControls(view) { controls in
            // A stepper's arrows, such as the Recordings group's days
            // stepper has, are AppKit buttons without labels: they say
            // nothing about whether SwiftUI exposes its own buttons.
            let labels = controls.filter { $0.role == .button && !$0.label.isEmpty }.map(\.label)
            guard !labels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertTrue(labels.contains(DataDirectoryMoveWording.cancelLabel), "\(labels)")
            XCTAssertTrue(labels.contains(StorageLocationWording.chooserLabel(isLibraryAvailable: true)), "\(labels)")
        }
    }

    // MARK: - Fixtures

    /// Storage settings for a library moving to a drive, `copiedPercent`
    /// copied.
    private func makeStorageSettingsShowingAMove(copiedPercent: Int) -> some View {
        let model = LibraryViewModel(initializeServices: false)
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        recordingAnnouncements {
            move.beginCopying()
            move.receive(DataDirectoryCopyProgress(
                copiedBytes: Int64(copiedPercent),
                totalBytes: 100,
                copiedItems: 3,
                totalItems: 5
            ))
        }
        model.dataDirectoryMove = move
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("StorageMoveProgress")
        )
        return StorageSettingsView()
            .environmentObject(model)
            .environmentObject(settings)
    }

    /// The determinate progress bars drawn in `view`: the move's, since no
    /// text extraction runs here.
    private func moveBars(in view: NSView) -> [NSProgressIndicator] {
        descendants(of: view, as: NSProgressIndicator.self).filter { !$0.isIndeterminate }
    }
}
