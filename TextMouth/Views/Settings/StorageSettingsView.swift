import SwiftUI
import os

/// A data-directory operation started from Storage settings.
enum StorageOperation: Equatable {
    /// Rebuild Directory.
    case rebuild
    /// Reset to Default: move the data back to ~/.TextMouth.
    case resetToDefault
    /// Change Location's Move Library Here: move the data into the given
    /// directory.
    case move(to: URL)
    /// Change Location's Use This Library, or Start New Library while the
    /// library isn't available: use the library in the given directory, or
    /// start one in the default location, by opening TextMouth again (FR02).
    case useLibrary(at: URL)

    /// What the status line says while the operation runs.
    var runningMessage: String {
        switch self {
        case .rebuild:
            // Translators: Storage settings status line while Rebuild Directory runs.
            return InterfaceText.line("storageOperation.runningMessage.rebuild", "Rebuilding the data directory...")
        case .resetToDefault:
            // Translators: Storage settings status line while Reset to Default Location runs.
            return InterfaceText.line("storageOperation.runningMessage.resetToDefault", "Moving data to the default location...")
        case .move(let destination):
            // Translators: Storage settings status line while the library moves to a chosen folder. %@ is the folder's path.
            return InterfaceText.line("storageOperation.runningMessage.move", "Moving data to \(destination.path)...")
        case .useLibrary(let folder):
            // Translators: Storage settings status line while TextMouth switches to the library in a chosen folder. %@ is the folder's path.
            return InterfaceText.line("storageOperation.runningMessage.useLibrary", "Switching to the library in \(folder.path)...")
        }
    }
}

/// The line under the storage buttons: what an operation is doing, what it
/// did, or why it failed (TODO A07). "Done" appears only after a success.
struct StorageStatus: Equatable {
    /// The words shown, which are also what VoiceOver reads and announces.
    let message: String
    /// Whether the line reports a refusal or failure, which is shown in red.
    /// The words say so too, so color is never the only signal.
    let isFailure: Bool

    /// The status while `operation` runs.
    static func running(_ operation: StorageOperation) -> StorageStatus {
        StorageStatus(message: operation.runningMessage, isFailure: false)
    }

    /// The status while the folder at `folder`, chosen for the library, is
    /// looked at before anything is offered (FR02).
    static func checking(_ folder: URL) -> StorageStatus {
        StorageStatus(
            // Translators: Storage settings status line while a chosen folder is looked at. %@ is the folder's path.
            message: InterfaceText.line("storageStatus.checking", "Checking \(folder.path)..."),
            isFailure: false
        )
    }

    /// The status once an operation has finished with `outcome`: its own
    /// words, which after a failure are those of the library's error alert.
    static func finished(_ outcome: OperationOutcome) -> StorageStatus {
        StorageStatus(message: outcome.message ?? StorageSettingsWording.done, isFailure: !outcome.succeeded)
    }

    /// The finished status, announced once. VoiceOver does not read a
    /// status line that changes by itself, so each operation's result is
    /// spoken when it is shown.
    @MainActor
    static func announced(after outcome: OperationOutcome) -> StorageStatus {
        finished(outcome).announced()
    }

    /// This status, announced once, as every status that changes while the
    /// user waits is: an operation's result, what a chosen folder can hold,
    /// and that a chosen folder is being looked at.
    @MainActor
    func announced() -> StorageStatus {
        VoiceOverAnnouncer.announce(message)
        return self
    }
}

/// The words of Storage settings' location controls (FR02), each defined
/// once for the screen, VoiceOver, and the tests.
enum StorageLocationWording {
    /// The sentence that says how many books of this library need a newer
    /// TextMouth (V03): kept in library.json as they are, not shown. Nil
    /// when none does, so nothing is shown.
    static func booksNeedingNewerTextMouth(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        // One sentence for each count: "It is kept" for one book, "They are kept" for more.
        if count == 1 {
            // Translators: Storage settings note: one book of the library was added by a newer TextMouth, which this one keeps but can't show.
            return InterfaceText.line("storageLocation.booksNeedingNewerTextMouth.needs", "1 book in this library needs a newer version of TextMouth. It is kept as it is, but not shown.")
        }
        // Translators: Storage settings note: several books of the library were added by a newer TextMouth, which this one keeps but can't show. %lld is how many books.
        return InterfaceText.line("storageLocation.booksNeedingNewerTextMouth.need", "\(number: count) books in this library need a newer version of TextMouth. They are kept as they are, but not shown.")
    }

    /// The button that opens the folder chooser: Change Location while the
    /// library is available, Choose Another Library while it isn't.
    static func chooserTitle(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            // Translators: Button in Storage settings that opens a folder chooser to move the library. The three dots show that a chooser opens.
            ? InterfaceText.line("storageLocation.chooserTitle.change", "Change Location...")
            // Translators: Button in Storage settings, shown while the library isn't available, that opens a folder chooser to pick another library. The three dots show that a chooser opens.
            : InterfaceText.line("storageLocation.chooserTitle.another", "Choose Another Library...")
    }

    /// What VoiceOver calls that button.
    static func chooserLabel(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            // Translators: VoiceOver label of the Change Location button in Storage settings.
            ? InterfaceText.line("storageLocation.chooserLabel.newLibrary", "Choose a new location for the library")
            // Translators: VoiceOver label of the Choose Another Library button in Storage settings.
            : InterfaceText.line("storageLocation.chooserLabel.another", "Choose another library")
    }

    /// What that button does.
    static func chooserHint(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            // Translators: VoiceOver hint of the Change Location button in Storage settings.
            ? InterfaceText.line("storageLocation.chooserHint.receives", "Opens a folder chooser. An empty folder receives a copy of the library; a folder that holds a TextMouth library can be used as it is.")
            // Translators: VoiceOver hint of the Choose Another Library button in Storage settings.
            : InterfaceText.line("storageLocation.chooserHint.instead", "Opens a folder chooser to pick a folder that holds a TextMouth library, which TextMouth then opens instead.")
    }

    /// The button, shown while the library isn't available, that opens the
    /// library in the default location, or starts a new one there.
    static var useDefaultTitle: String {
        // Translators: Button in Storage settings, shown while the library isn't available, that opens the library in the default location or starts a new one there. The three dots show that a question follows.
        InterfaceText.line("storageLocation.useDefaultTitle", "Use Default Location...")
    }
    /// What VoiceOver calls it.
    static var useDefaultLabel: String {
        // Translators: VoiceOver label of the Use Default Location button in Storage settings.
        InterfaceText.line("storageLocation.useDefaultLabel", "Use the default location")
    }
    /// What it does.
    static var useDefaultHint: String {
        // Translators: VoiceOver hint of the Use Default Location button in Storage settings. ~/.TextMouth is the default folder's path and stays as written.
        InterfaceText.line("storageLocation.useDefaultHint", "Opens the library in the default location, ~/.TextMouth, or starts a new one there, instead of the library that isn't available.")
    }

    /// The folder chooser's title.
    static func panelTitle(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            // Translators: Title of the folder chooser that Change Location opens.
            ? InterfaceText.line("storageLocation.panelTitle.library", "Choose a Location for the Library")
            // Translators: Title of the folder chooser that Choose Another Library opens.
            : InterfaceText.line("storageLocation.panelTitle.another", "Choose Another Library")
    }

    /// What the folder chooser explains.
    static func panelMessage(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            ? SentenceWording.joined([
                // Translators: First sentence of the message of the folder chooser that Change Location opens.
                InterfaceText.line("storageLocation.panelMessage.empty", "Choose an empty folder to move the library into, or a folder that holds a TextMouth library to use it."),
                // Translators: Last sentence of the message of the folder chooser that Change Location opens: the chooser has a button that makes a folder.
                InterfaceText.line("storageLocation.panelMessage.make", "You can make a new folder here."),
            ])
            // Translators: Message of the folder chooser that Choose Another Library opens.
            : InterfaceText.line("storageLocation.panelMessage.instead", "Choose a folder that holds a TextMouth library to use it instead.")
    }

    /// The folder chooser's button, which names the action.
    static func panelPrompt(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            // Translators: Button of the folder chooser that Change Location opens: picks the folder.
            ? InterfaceText.line("storageLocation.panelPrompt.choose", "Choose Location")
            // Translators: Button of the folder chooser that Choose Another Library opens: picks the folder.
            : InterfaceText.line("storageLocation.panelPrompt.library", "Choose Library")
    }
}

/// The words of Storage settings' other controls and alerts, each defined
/// once for the screen, VoiceOver, and the tests.
enum StorageSettingsWording {
    /// The status after an operation that has nothing more to say.
    static var done: String {
        // Translators: Storage settings status line after an operation finished and has nothing more to say.
        InterfaceText.line("common.doneSentence", "Done.")
    }

    /// The status's words for each state of the data directory.
    static var changesNotSaved: String {
        // Translators: Storage settings status: some changes could not be saved.
        InterfaceText.line("storageSettings.changesNotSaved", "Changes not saved")
    }
    static var active: String {
        // Translators: Storage settings status: the data directory exists and is working.
        InterfaceText.line("storageSettings.active", "Active")
    }
    static var notCreated: String {
        // Translators: Storage settings status: the data directory does not exist yet.
        InterfaceText.line("storageSettings.notCreated", "Not Created")
    }

    /// Begins the message when moving the data directory failed; the reason follows after a colon.
    static var moveFailureContext: String {
        // Translators: Begins the message when moving the data directory failed; the reason follows after a colon.
        InterfaceText.line("storageSettings.moveFailureContext", "Failed to move directory")
    }

    // MARK: The Storage Directory Section
    static var storageDirectoryHeader: String {
        // Translators: Heading of the first section of Storage settings, about where the library lives.
        InterfaceText.line("storageSettings.storageDirectoryHeader", "Storage Directory")
    }
    static var customLocation: String {
        // Translators: Under the data directory's path in Storage settings: the library is not in the default location.
        InterfaceText.line("storageSettings.customLocation", "Custom location")
    }
    static var defaultLocation: String {
        // Translators: Under the data directory's path in Storage settings: the library is in the default location.
        InterfaceText.line("storageSettings.defaultLocation", "Default location")
    }
    static func dataDirectoryLabel(path: String) -> String {
        // Translators: VoiceOver label of the data directory's row in Storage settings. %@ is the folder's path.
        InterfaceText.line("storageSettings.dataDirectoryLabel", "Data directory: \(path)")
    }
    static var statusLabel: String {
        // Translators: Label of the data directory's status row in Storage settings.
        InterfaceText.line("common.status", "Status")
    }
    static var retrySavingTitle: String {
        // Translators: Button in Storage settings that tries again to save changes that could not be saved.
        InterfaceText.line("storageSettings.retrySavingTitle", "Retry Saving")
    }
    static var retrySavingHint: String {
        // Translators: VoiceOver hint of the Retry Saving button in Storage settings.
        InterfaceText.line("storageSettings.retrySavingHint", "Tries again to save every change that could not be saved")
    }
    static var rebuildDirectoryTitle: String {
        // Translators: Button in Storage settings that rebuilds the data directory's structure. Also the title of its confirmation.
        InterfaceText.line("storageSettings.rebuildDirectoryTitle", "Rebuild Directory")
    }
    static var rebuildDirectoryLabel: String {
        // Translators: VoiceOver label of the Rebuild Directory button in Storage settings.
        InterfaceText.line("storageSettings.rebuildDirectoryLabel", "Rebuild TextMouth directory")
    }
    static var rebuildDirectoryHint: String {
        // Translators: VoiceOver hint of the Rebuild Directory button in Storage settings.
        InterfaceText.line("storageSettings.rebuildDirectoryHint", "Recreates the directory structure and migrates any books using old storage")
    }
    static var resetToDefaultTitle: String {
        // Translators: Button in Storage settings that moves the library back to the default location.
        InterfaceText.line("common.resetToDefault", "Reset to Default")
    }
    static var resetToDefaultLabel: String {
        // Translators: VoiceOver label of the Reset to Default button in Storage settings.
        InterfaceText.line("storageSettings.resetToDefaultLabel", "Reset to default location")
    }
    static var resetToDefaultHint: String {
        // Translators: VoiceOver hint of the Reset to Default button in Storage settings. ~/.TextMouth is the default folder's path and stays as written.
        InterfaceText.line("storageSettings.resetToDefaultHint", "Moves data back to the default location at ~/.TextMouth")
    }

    // MARK: The Import and Removal Sections
    static var afterImportingTitle: String {
        // Translators: Label of the pop-up in Storage settings that says what to do with a book's original file after importing it.
        InterfaceText.line("storageSettings.afterImportingTitle", "After Importing a Book")
    }
    static var originalFileLabel: String {
        // Translators: VoiceOver label of the After Importing a Book pop-up in Storage settings.
        InterfaceText.line("storageSettings.originalFileLabel", "Original file handling")
    }
    static var originalFileHint: String {
        // Translators: VoiceOver hint of the After Importing a Book pop-up in Storage settings.
        InterfaceText.line("storageSettings.originalFileHint", "What to do with the original file after importing a book")
    }
    static var originalRemains: String {
        // Translators: Caption in Storage settings when the original file is kept after an import.
        InterfaceText.line("storageSettings.originalRemains", "The original file will remain untouched after import.")
    }
    static var importBehaviorHeader: String {
        // Translators: Heading of the section of Storage settings about what an import does.
        InterfaceText.line("storageSettings.importBehaviorHeader", "Import Behavior")
    }
    static var confirmBeforeRemovingTitle: String {
        // Translators: Checkbox in Storage settings: ask before a book is removed.
        InterfaceText.line("storageSettings.confirmBeforeRemovingTitle", "Confirm before removing a book")
    }
    static var moveToTrashTitle: String {
        // Translators: Checkbox in Storage settings: removed books' files go to the Trash instead of being deleted at once.
        InterfaceText.line("storageSettings.moveToTrashTitle", "Move to Trash instead of deleting")
    }
    static var removalBehaviorHeader: String {
        // Translators: Heading of the section of Storage settings about what removing a book does.
        InterfaceText.line("storageSettings.removalBehaviorHeader", "Removal Behavior")
    }
    static var libraryStatisticsHeader: String {
        // Translators: Heading of the section of Storage settings that lists counts about the library.
        InterfaceText.line("storageSettings.libraryStatisticsHeader", "Library Statistics")
    }

    // MARK: The Maintenance Section
    static var findDuplicatesTitle: String {
        // Translators: Button in Storage settings that opens the duplicate finder. The three dots show that a window opens.
        InterfaceText.line("storageSettings.findDuplicatesTitle", "Find Duplicate Books...")
    }
    static var findDuplicatesLabel: String {
        // Translators: VoiceOver label of the Find Duplicate Books button in Storage settings.
        InterfaceText.line("storageSettings.findDuplicatesLabel", "Find duplicate books")
    }
    static var findDuplicatesHint: String {
        // Translators: VoiceOver hint of the Find Duplicate Books button in Storage settings.
        InterfaceText.line("storageSettings.findDuplicatesHint", "Scans the library for books with matching files, titles, or authors")
    }
    static var findDuplicatesCaption: String {
        // Translators: Caption under the Find Duplicate Books button in Storage settings.
        InterfaceText.line("storageSettings.findDuplicatesCaption", "Finds duplicate books in all folders by file content, title, or author.")
    }
    static var redoExtractionTitle: String {
        // Translators: Button in Storage settings that reads every book's text again. The three dots show that a question follows.
        InterfaceText.line("storageSettings.redoExtractionTitle", "Redo Text Extraction...")
    }
    static var redoExtractionLabel: String {
        // Translators: VoiceOver label of the Redo Text Extraction button in Storage settings.
        InterfaceText.line("storageSettings.redoExtractionLabel", "Redo text extraction")
    }
    static var redoExtractionHint: String {
        // Translators: VoiceOver hint of the Redo Text Extraction button in Storage settings.
        InterfaceText.line("storageSettings.redoExtractionHint", "Re-extracts cached text from all books. Useful after parser fixes or format improvements.")
    }
    static func extractionProgress(current: Int, total: Int) -> String {
        // Translators: How far Redo Text Extraction has got, beside its progress bar. %1$lld is how many books are done; %2$lld is how many books there are.
        InterfaceText.line("storageSettings.extractionProgress", "\(number: current)/\(number: total)")
    }
    static func extractionProgressLabel(current: Int, total: Int) -> String {
        // Translators: VoiceOver label of the progress of Redo Text Extraction. %1$lld is how many books are done; %2$lld is how many books there are.
        InterfaceText.line("storageSettings.extractionProgressLabel", "Text extraction progress: \(number: current) of \(number: total)")
    }
    static var redoExtractionCaption: String {
        SentenceWording.joined([
            // Translators: First sentence of the caption under the Redo Text Extraction button in Storage settings.
            InterfaceText.line("storageSettings.redoExtractionCaption.extracts", "Re-extracts every book's cached text."),
            // Translators: Last sentence of the caption under the Redo Text Extraction button in Storage settings. "It" is Redo Text Extraction.
            InterfaceText.line("storageSettings.redoExtractionCaption.updates", "Use it after parser updates."),
        ])
    }
    static var libraryMaintenanceHeader: String {
        // Translators: Heading of the section of Storage settings with the duplicate finder and Redo Text Extraction.
        InterfaceText.line("storageSettings.libraryMaintenanceHeader", "Library Maintenance")
    }

    // MARK: The Alerts
    static var cancelTitle: String {
        // Translators: Button of a confirmation in Storage settings that changes nothing.
        InterfaceText.line("common.cancel", "Cancel")
    }
    static var rebuildButtonTitle: String {
        // Translators: Button of the Rebuild Directory confirmation that rebuilds the directory.
        InterfaceText.line("storageSettings.rebuildButtonTitle", "Rebuild")
    }
    static var rebuildMessage: String {
        SentenceWording.joined([
            // Translators: First sentence of the Rebuild Directory confirmation.
            InterfaceText.line("storageSettings.rebuildMessage.recreates", "This recreates the directory structure and migrates books using old storage."),
            // Translators: Last sentence of the Rebuild Directory confirmation.
            InterfaceText.line("storageSettings.rebuildMessage.positions", "Your books and reading positions are kept."),
        ])
    }
    static var resetAlertTitle: String {
        // Translators: Title of the question asked before moving the library back to the default location.
        InterfaceText.line("storageSettings.resetAlertTitle", "Reset to Default Location?")
    }
    static var resetAndMoveTitle: String {
        // Translators: Button of the Reset to Default Location question that moves the library.
        InterfaceText.line("storageSettings.resetAndMoveTitle", "Reset & Move")
    }
    static func resetMessage(from root: String, to defaultRoot: String) -> String {
        // Translators: Message of the question asked before moving the library back to the default location. %1$@ is the current folder's path; %2$@ is the default folder's path.
        InterfaceText.line("storageSettings.resetMessage", "This moves all data from \(root) back to the default location, \(defaultRoot).")
    }
    static var redoAlertTitle: String {
        // Translators: Title of the question asked before Redo Text Extraction.
        InterfaceText.line("storageSettings.redoAlertTitle", "Redo Text Extraction?")
    }
    static var reExtractAllTitle: String {
        // Translators: Button of the Redo Text Extraction question that starts the extraction.
        InterfaceText.line("storageSettings.reExtractAllTitle", "Re-extract All")
    }
    static var redoMessage: String {
        SentenceWording.joined([
            // Translators: First sentence of the Redo Text Extraction question.
            InterfaceText.line("storageSettings.redoMessage.extracts", "This re-extracts the cached text of every book, which may take a while for a large library."),
            // Translators: Last sentence of the Redo Text Extraction question.
            InterfaceText.line("storageSettings.redoMessage.positions", "Reading positions are kept, but character offsets may shift slightly if the text changes."),
        ])
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    /// The import choice, which the settings model reads from config.json
    /// and announces whenever it changes, an edit of the file included.
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The removal choices, shared with the library's windows and menus and
    /// kept in step with config.json, so the toggles always show, and
    /// VoiceOver always reads, the choices in force (TODO C04).
    @ObservedObject private var removal = RemovalPreferencesModel.shared
    @State private var showRebuildConfirmation = false
    @State private var showResetToDefaultConfirmation = false
    /// What a folder chosen for the library offers, waiting for the user to
    /// confirm it (FR02).
    @State private var pendingConfirmation: PendingConfirmation?
    /// Whether a chosen folder is being looked at.
    @State private var isAssessing = false
    /// While Use This Library compares the two copies, the switch Stop Comparing sets.
    @State private var comparisonStop: OSAllocatedUnfairLock<Bool>?
    /// What the last data-directory operation is doing or did.
    @State private var status: StorageStatus?
    /// The data-directory operation in progress, if any.
    @State private var runningOperation: StorageOperation?
    @State private var showDuplicateFinder = false
    /// The copy of the library a listener chose to compare with this one
    /// (Compare Libraries), whose sheet is showing.
    @State private var compareRequest: CompareRequest?
    @State private var showRedoExtractionConfirmation = false
    /// What the last Redo Text Extraction did, once it is done.
    @State private var extractionStatus: StorageStatus?
    /// Failed writes, so the status never says all is well while changes
    /// are unsaved (TODO S09).
    @ObservedObject private var failureCenter = PersistenceFailureCenter.shared
    /// Whether the data directory exists, as last checked (PERF32). The
    /// Status line used to ask the disk twice on every draw, on the main
    /// thread, once a second while a book played, and a network or
    /// unplugged volume can block there. It is checked off the main thread
    /// when the pane appears, after each data-directory operation, and when
    /// the library's folder or its availability changes. Until the first
    /// answer the directory counts as there, as it nearly always is.
    @State private var directoryExists = true
    /// Bumped as each data-directory operation ends, to check again.
    @State private var directoryCheckRequest = 0

    /// Whether a folder exists at a path: how the pane checks the data
    /// directory, off the main thread. A test puts in its own to count the
    /// checks and see where they run, and puts this one back, as tests do
    /// with `CloudServices`.
    static var directoryCheck: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// What the data directory check depends on: when any of it changes,
    /// the directory is checked again.
    private struct DirectoryCheckKey: Equatable {
        /// The data directory's path.
        let root: String
        /// Whether the library could be used there, at the last look.
        let isAvailable: Bool
        /// How many data-directory operations have ended.
        let request: Int
    }

    /// A folder chosen to compare with the library in use. Each choice is its
    /// own, so choosing the same folder again opens the sheet again.
    private struct CompareRequest: Identifiable {
        let id = UUID()
        let folder: URL
    }

    /// A choice offered for a chosen folder: an alert titled `title`,
    /// explaining `message`, whose confirming `button` does `action`.
    private struct PendingConfirmation: Equatable {
        let title: String
        let message: String
        let button: String
        let action: StorageChoice.Action
    }

    var body: some View {
        let _ = ViewBodyCounter.record("StorageSettingsView")
        let directoryCheckKey = DirectoryCheckKey(
            root: TextMouthPaths.rootPath,
            isAvailable: unavailability == nil,
            request: directoryCheckRequest
        )
        Form {
            Section {
                LabeledContent(DataDirectoryUnavailableText.locationLabel) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(TextMouthPaths.rootPath)
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .font(.caption)

                        if TextMouthPaths.isCustomPath {
                            Text(StorageSettingsWording.customLocation)
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else {
                            Text(StorageSettingsWording.defaultLocation)
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
                .accessibilityLabel(StorageSettingsWording.dataDirectoryLabel(path: TextMouthPaths.rootPath))

                LabeledContent(StorageSettingsWording.statusLabel) {
                    Text(Self.statusText(
                        isRecoveringIndex: isRecoveringIndex,
                        directoryExists: directoryExists,
                        hasUnsavedChanges: hasUnsavedChanges,
                        isLibraryUnavailable: unavailability != nil,
                        unavailableStatus: unavailability.map(DataDirectoryUnavailableText.title(for:))
                            ?? DataDirectoryUnavailableText.title
                    ))
                    .foregroundColor(
                        unavailability != nil || isRecoveringIndex || hasUnsavedChanges
                            || !directoryExists ? .red : .green
                    )
                }

                // Books a newer TextMouth added, which this one keeps but
                // cannot show (V03): plain text, read in order with the
                // Status row above it.
                if let newerBooks = StorageLocationWording.booksNeedingNewerTextMouth(
                    libraryViewModel.booksNeedingNewerTextMouth
                ) {
                    Text(newerBooks)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let unavailability {
                    // The reason the Library window's screen gives (FR02).
                    Text(unavailability.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isRecoveringIndex {
                    Text(LibraryIndexRecoveryText.settingsExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if hasUnsavedChanges {
                    // What is unsaved and why, and a way to try again here,
                    // even when the Library window's notice was dismissed.
                    Text(Self.unsavedExplanation(failureCenter.unsavedRows))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(StorageSettingsWording.retrySavingTitle) {
                        failureCenter.retryUnsavedChanges(announcing: true)
                    }
                    .accessibilityHint(StorageSettingsWording.retrySavingHint)
                }

                locationButtons

                Button(StorageSettingsWording.rebuildDirectoryTitle) {
                    showRebuildConfirmation = true
                }
                .disabled(maintenanceUnavailable)
                .accessibilityLabel(StorageSettingsWording.rebuildDirectoryLabel)
                .accessibilityHint(StorageSettingsWording.rebuildDirectoryHint)

                // While the library moves, its progress and Cancel, as every
                // Library window's sheet shows them (FR02); otherwise what
                // the last operation did.
                if let move = libraryViewModel.dataDirectoryMove {
                    DataDirectoryMoveProgressView(move: move)
                } else if let status {
                    Text(status.message)
                        .font(.caption)
                        .foregroundColor(status.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The comparison that says which copy is newer can last up to
                // a minute: it can be stopped.
                if let comparisonStop {
                    Button(LibraryComparisonWording.stopForUseLabel) {
                        comparisonStop.withLock { $0 = true }
                    }
                    .accessibilityHint(LibraryComparisonWording.stopHint)
                }
            } header: {
                Text(StorageSettingsWording.storageDirectoryHeader)
            }

            Section {
                Picker(StorageSettingsWording.afterImportingTitle, selection: $settingsViewModel.importDeleteBehavior) {
                    ForEach(ImportDeleteBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .accessibilityLabel(StorageSettingsWording.originalFileLabel)
                .accessibilityHint(StorageSettingsWording.originalFileHint)

                // Deleting the original follows "Move to Trash instead of
                // deleting" below, so these say which it will be.
                switch settingsViewModel.importDeleteBehavior {
                case .keepOriginal:
                    Text(StorageSettingsWording.originalRemains)
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .deleteAfterImport:
                    Text(originalFileWording.automaticDeletionExplanation)
                        .font(.caption)
                        .foregroundColor(.orange)
                case .askEachTime:
                    Text(originalFileWording.askingExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Whether an import also keeps the original of the audio it
                // converts (off by default); the caption says what the
                // present state means.
                Toggle(ConvertedOriginalWording.label, isOn: $settingsViewModel.keepsOriginalOfConvertedAudio)
                    .accessibilityHint(ConvertedOriginalWording.hint)
                Text(ConvertedOriginalWording.caption(keeping: settingsViewModel.keepsOriginalOfConvertedAudio))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(StorageSettingsWording.importBehaviorHeader)
            }

            Section {
                Toggle(StorageSettingsWording.confirmBeforeRemovingTitle, isOn: Binding(
                    get: { removal.preferences.confirmsFirst },
                    set: { removal.setConfirmsFirst($0) }
                ))
                .accessibilityHint(removalPreferences.confirmationExplanation)

                Toggle(StorageSettingsWording.moveToTrashTitle, isOn: Binding(
                    get: { removal.preferences.movesToTrash },
                    set: { removal.setMovesToTrash($0) }
                ))
                .accessibilityHint(RemovalPreferences.trashPreferenceExplanation)

                // What deleting does now, beside Remove from Library Only,
                // which always keeps the files (TODO A08).
                Text(removalPreferences.deletionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(StorageSettingsWording.removalBehaviorHeader)
            }

            Section {
                let statistics = LibraryStatistics(
                    library: libraryViewModel.library,
                    feedCount: libraryViewModel.feeds.store.records.count
                )
                ForEach(statistics.lines) { line in
                    LabeledContent(line.label) {
                        Text(line.value)
                    }
                }
            } header: {
                Text(StorageSettingsWording.libraryStatisticsHeader)
            }

            Section {
                Button(StorageSettingsWording.findDuplicatesTitle) {
                    showDuplicateFinder = true
                }
                // Removing a duplicate changes the library, which must not
                // change while it moves (FR02).
                .disabled(isMovingLibrary)
                .accessibilityLabel(StorageSettingsWording.findDuplicatesLabel)
                .accessibilityHint(StorageSettingsWording.findDuplicatesHint)

                Text(StorageSettingsWording.findDuplicatesCaption)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // The batch's own progress object: only this part redraws as
                // each book finishes (TODO PERF12).
                ProgressObserver(progress: libraryViewModel.textExtraction) { extraction in
                    Button(StorageSettingsWording.redoExtractionTitle) {
                        showRedoExtractionConfirmation = true
                    }
                    .disabled(extraction.isExtracting || isMovingLibrary)
                    .accessibilityLabel(StorageSettingsWording.redoExtractionLabel)
                    .accessibilityHint(StorageSettingsWording.redoExtractionHint)

                    if extraction.isExtracting {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(extraction.current),
                                         total: Double(max(extraction.total, 1)))
                                .progressViewStyle(.linear)
                            Text(StorageSettingsWording.extractionProgress(current: extraction.current, total: extraction.total))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(StorageSettingsWording.extractionProgressLabel(current: extraction.current, total: extraction.total))
                    } else {
                        Text(StorageSettingsWording.redoExtractionCaption)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // What the last run did, such as how many books in the
                        // cloud it skipped (FR02).
                        if let extractionStatus {
                            Text(extractionStatus.message)
                                .font(.caption)
                                .foregroundColor(extractionStatus.isFailure ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text(StorageSettingsWording.libraryMaintenanceHeader)
            }

            // Syncing the library with the iPhone through iCloud Drive (FR43).
            #if os(macOS)
            SyncSettingsSection()
            #endif

            // What happens to the original audio of recordings and edited
            // audiobooks (FR04).
            AudioEditingSettingsSection()

            // Where the diagnostic logs are written, where they are now, and
            // a way to show them in Finder (the user's decision of October 3).
            LogsSettingsSection()
        }
        .padding()
        // Checked off the main thread on appearing, and again whenever what
        // the check depends on changes (PERF32).
        .task(id: directoryCheckKey) {
            directoryExists = await Self.directoryExists(at: directoryCheckKey.root)
        }
        .alert(StorageSettingsWording.rebuildDirectoryTitle, isPresented: $showRebuildConfirmation) {
            Button(StorageSettingsWording.rebuildButtonTitle) {
                start(.rebuild)
            }
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
        } message: {
            Text(StorageSettingsWording.rebuildMessage)
        }
        .alert(StorageSettingsWording.resetAlertTitle, isPresented: $showResetToDefaultConfirmation) {
            Button(StorageSettingsWording.resetAndMoveTitle) {
                start(.resetToDefault)
            }
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
        } message: {
            Text(StorageSettingsWording.resetMessage(from: TextMouthPaths.rootPath, to: TextMouthPaths.defaultRoot.path))
        }
        // What a chosen folder offers: Move Library Here, Use This Library,
        // or Start New Library (FR02).
        .alert(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button(confirmation.button) {
                carryOut(confirmation.action)
            }
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert(StorageSettingsWording.redoAlertTitle, isPresented: $showRedoExtractionConfirmation) {
            Button(StorageSettingsWording.reExtractAllTitle) {
                redoTextExtraction()
            }
            Button(StorageSettingsWording.cancelTitle, role: .cancel) {}
        } message: {
            Text(StorageSettingsWording.redoMessage)
        }
        .sheet(isPresented: $showDuplicateFinder) {
            DuplicateFinderView(libraryViewModel: libraryViewModel)
        }
        .sheet(item: $compareRequest) { request in
            CompareLibrariesSheet(model: LibraryComparisonModel(
                otherFolder: request.folder,
                thisFolder: TextMouthPaths.root,
                thisLibrary: libraryViewModel.library,
                reader: .app()
            ))
        }
    }

    /// The buttons that choose where the library is (FR02). While the
    /// library is available: Change Location, which opens the folder
    /// chooser, and Reset to Default for a custom location. While it isn't:
    /// Choose Another Library, and Use Default Location, which opens the
    /// library in the default location or starts a new one there; nothing
    /// can be moved or rebuilt then, and nothing is created at the missing
    /// location.
    @ViewBuilder
    private var locationButtons: some View {
        let isAvailable = unavailability == nil
        HStack {
            Button(StorageLocationWording.chooserTitle(isLibraryAvailable: isAvailable)) {
                chooseFolder()
            }
            .accessibilityLabel(StorageLocationWording.chooserLabel(isLibraryAvailable: isAvailable))
            .accessibilityHint(StorageLocationWording.chooserHint(isLibraryAvailable: isAvailable))

            if !isAvailable {
                Button(StorageLocationWording.useDefaultTitle) {
                    assess(TextMouthPaths.defaultRoot)
                }
                .accessibilityLabel(StorageLocationWording.useDefaultLabel)
                .accessibilityHint(StorageLocationWording.useDefaultHint)
            } else {
                // Beside the buttons that choose another library, whose
                // confirmation points here: a read-only look at what another
                // copy of this library holds that this one doesn't.
                Button(LibraryComparisonWording.buttonTitle) {
                    chooseFolderToCompare()
                }
                .accessibilityLabel(LibraryComparisonWording.title)
                .accessibilityHint(LibraryComparisonWording.buttonHint)
                if TextMouthPaths.isCustomPath {
                    Button(StorageSettingsWording.resetToDefaultTitle) {
                        showResetToDefaultConfirmation = true
                    }
                    .disabled(maintenanceUnavailable)
                    .accessibilityLabel(StorageSettingsWording.resetToDefaultLabel)
                    .accessibilityHint(StorageSettingsWording.resetToDefaultHint)
                }
            }
        }
        .disabled(chooserUnavailable)
    }

    /// Whether the library index could not be read and is being recovered.
    private var isRecoveringIndex: Bool {
        libraryViewModel.indexRecovery != nil
    }

    /// Why the data directory can't be used, while it can't (FR02).
    private var unavailability: DataDirectoryUnavailability? {
        libraryViewModel.dataDirectoryUnavailability
    }

    /// Whether the library is moving, from here or as config.json asked.
    private var isMovingLibrary: Bool {
        libraryViewModel.dataDirectoryMove != nil
    }

    /// Whether a data-directory operation, or the look at a chosen folder,
    /// is under way.
    private var isRunning: Bool {
        runningOperation != nil || isAssessing || isMovingLibrary
    }

    /// The removal preferences in force, which this pane's toggles show.
    private var removalPreferences: RemovalPreferences {
        removal.preferences
    }

    /// The words for deleting an import's original file, under the Trash
    /// preference in force.
    private var originalFileWording: OriginalFileDeletionWording {
        OriginalFileDeletionWording(movesToTrash: removalPreferences.movesToTrash)
    }

    /// Whether a failed write leaves changes unsaved, as last published.
    private var hasUnsavedChanges: Bool {
        !failureCenter.unsavedRows.isEmpty
    }

    /// Whether the reset and rebuild buttons are unavailable right now.
    private var maintenanceUnavailable: Bool {
        Self.maintenanceUnavailable(
            isRecoveringIndex: isRecoveringIndex,
            isRunning: isRunning,
            isLibraryUnavailable: unavailability != nil
        )
    }

    /// Whether the folder chooser's buttons are unavailable right now.
    private var chooserUnavailable: Bool {
        Self.chooserUnavailable(isRecoveringIndex: isRecoveringIndex, isRunning: isRunning)
    }

    /// Whether the reset and rebuild buttons are unavailable: while the
    /// library index cannot be read, since they would act on the temporary
    /// library, while the library isn't available at all (FR02), since
    /// there is nothing to copy or rebuild, and while one of them runs. Once
    /// an operation ends, whether it worked or failed, they are available
    /// again, so a failure can be retried.
    nonisolated static func maintenanceUnavailable(
        isRecoveringIndex: Bool,
        isRunning: Bool,
        isLibraryUnavailable: Bool = false
    ) -> Bool {
        isRecoveringIndex || isRunning || isLibraryUnavailable
    }

    /// Whether Change Location, or Choose Another Library and Use Default
    /// Location, are unavailable: while the library index cannot be read,
    /// whose recovery has options of its own, and while an operation runs
    /// or a chosen folder is looked at. While the library isn't available
    /// they stay available: choosing another library is the way out when
    /// its drive is gone for good (FR02).
    nonisolated static func chooserUnavailable(isRecoveringIndex: Bool, isRunning: Bool) -> Bool {
        isRecoveringIndex || isRunning
    }

    /// The data directory status, as shown and as VoiceOver reads it. A
    /// library that isn't available outranks everything (FR02); an
    /// unreadable library index outranks "Active": the directory exists, but
    /// its library index is not being saved. So do unsaved changes (TODO
    /// S09): a directory whose writes fail is not working as it should.
    nonisolated static func statusText(
        isRecoveringIndex: Bool,
        directoryExists: Bool,
        hasUnsavedChanges: Bool = false,
        isLibraryUnavailable: Bool = false,
        unavailableStatus: String = DataDirectoryUnavailableText.title
    ) -> String {
        if isLibraryUnavailable {
            return unavailableStatus
        }
        if isRecoveringIndex {
            return LibraryIndexRecoveryText.settingsStatus
        }
        if hasUnsavedChanges {
            return StorageSettingsWording.changesNotSaved
        }
        return directoryExists ? StorageSettingsWording.active : StorageSettingsWording.notCreated
    }

    /// What the status explains while changes are unsaved: each unsaved
    /// subsystem's sentence, as the Library window's notice words it.
    nonisolated static func unsavedExplanation(_ rows: [PersistenceBannerRow]) -> String {
        SentenceWording.joined(rows.map(\.text))
    }

    // MARK: - Choosing a Folder (FR02)

    #if os(macOS)
    /// The folder chooser Change Location and Choose Another Library open:
    /// any one folder, hidden ones shown, as this user keeps them, with a
    /// button that makes a new folder and a prompt naming the action. The
    /// chosen folder itself is the data directory; nothing is added to it.
    /// It starts in the folder holding the data directory, when that exists.
    @MainActor
    static func makeLibraryFolderPanel(isLibraryAvailable: Bool) -> FolderPanelSettings {
        FolderPanelSettings(
            canCreateDirectories: true,
            showsHiddenFiles: true,
            title: StorageLocationWording.panelTitle(isLibraryAvailable: isLibraryAvailable),
            message: StorageLocationWording.panelMessage(isLibraryAvailable: isLibraryAvailable),
            prompt: StorageLocationWording.panelPrompt(isLibraryAvailable: isLibraryAvailable),
            directoryURL: existingFolderHoldingTheLibrary()
        )
    }

    /// The folder that holds the data directory, or nil when it doesn't
    /// exist, where the storage choosers start.
    private static func existingFolderHoldingTheLibrary() -> URL? {
        let holder = TextMouthPaths.root.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: holder.path) ? holder : nil
    }
    #endif

    /// The folder chooser Compare Libraries opens: one folder, hidden ones
    /// shown, with a prompt that names the action. It chooses nothing to
    /// change: both copies are only read.
    #if os(macOS)
    @MainActor
    static func makeCompareFolderPanel() -> FolderPanelSettings {
        FolderPanelSettings(
            showsHiddenFiles: true,
            title: LibraryComparisonWording.panelTitle,
            message: LibraryComparisonWording.panelMessage,
            prompt: LibraryComparisonWording.panelPrompt,
            directoryURL: existingFolderHoldingTheLibrary()
        )
    }
    #endif

    /// Opens the folder chooser, as a sheet on the Settings window, and
    /// shows the Compare Libraries sheet for the folder chosen.
    private func chooseFolderToCompare() {
        #if os(macOS)
        let panel = Self.makeCompareFolderPanel().makePanel()
        let compareChosenFolder: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            compareRequest = CompareRequest(folder: folder)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: compareChosenFolder)
        } else {
            panel.begin(completionHandler: compareChosenFolder)
        }
        #else
        // Phase 0: iOS has no folder panel yet, as for choosing a library.
        #endif
    }

    /// Opens the folder chooser, as a sheet on the Settings window, and
    /// looks at the folder chosen.
    private func chooseFolder() {
        #if os(macOS)
        let panel = Self.makeLibraryFolderPanel(isLibraryAvailable: unavailability == nil).makePanel()
        let assessChosenFolder: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            assess(folder)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: assessChosenFolder)
        } else {
            panel.begin(completionHandler: assessChosenFolder)
        }
        #else
        // Phase 0: iOS has no folder panel, so choosing a folder does nothing yet; phase 1 uses a file importer.
    #endif
    }

    /// Looks at `folder` off the main thread (`StorageDestinationAssessment`)
    /// and offers what it can hold: a confirmation for Move Library Here,
    /// Use This Library, or Start New Library, or a sentence in the status
    /// line for the library in use or a folder refused, said why.
    private func assess(_ folder: URL) {
        guard !isRunning else { return }
        isAssessing = true
        status = StorageStatus.checking(folder).announced()
        Task { @MainActor in
            let assessment = await StorageDestinationAssessment.assess(folder, for: libraryViewModel)
            let comparison = await compareWithLibraryInUse(assessment)
            isAssessing = false
            offer(StorageChoice(for: assessment, current: currentLibrary, comparison: comparison))
        }
    }

    /// For a folder holding another copy of the library in use, compares the
    /// two off the main thread, so the confirmation can say which is newer.
    /// The reading waits at most a minute in all, and changes neither copy.
    /// Nil for any other folder, or while the library isn't available.
    private func compareWithLibraryInUse(_ assessment: StorageDestinationAssessment) async -> LibraryComparisonOutcome? {
        guard case .useLibrary(let found) = assessment.verdict, found.isCopyOfCurrentLibrary, unavailability == nil else {
            return nil
        }
        status = StorageStatus(message: LibraryComparisonWording.comparingForUseSentence, isFailure: false).announced()
        // A minute in all: this is a question put to the listener, who is waiting.
        let reader = { () -> LibraryCopyReader in
            var reader = LibraryCopyReader.app()
            reader.overallLimit = 60
            return reader
        }()
        let thisLibrary = libraryViewModel.library
        let thisFolder = TextMouthPaths.root
        let otherFolder = assessment.folder
        let stop = OSAllocatedUnfairLock(initialState: false)
        comparisonStop = stop
        defer { comparisonStop = nil }
        return await OffMainWork.run {
            reader.compare(
                thisFolder: thisFolder,
                thisLibrary: thisLibrary,
                otherFolder: otherFolder,
                isCancelled: { stop.withLock { $0 } }
            )
        }
    }

    /// Offers `choice`. A move is refused at once while a book is open,
    /// naming the books, as the move itself would refuse it.
    private func offer(_ choice: StorageChoice) {
        switch choice {
        case .confirm(let title, let message, let button, let action):
            if case .move = action, let refusal = libraryViewModel.openBooksRefusal {
                status = .announced(after: .failure(StorageSettingsWording.moveFailureContext, refusal))
                return
            }
            status = nil
            pendingConfirmation = PendingConfirmation(title: title, message: message, button: button, action: action)
        case .report(let message, let isRefusal):
            status = StorageStatus(message: message, isFailure: isRefusal).announced()
        }
    }

    /// Carries out a confirmed choice.
    private func carryOut(_ action: StorageChoice.Action) {
        switch action {
        case .move(let folder):
            start(.move(to: folder))
        case .useLibrary(let folder):
            start(.useLibrary(at: folder))
        }
    }

    /// The library in use, as the choices' words name it: while it isn't
    /// available, with the changes it couldn't take, which switching loses.
    private var currentLibrary: StorageChoice.CurrentLibrary {
        let isAvailable = unavailability == nil
        return StorageChoice.CurrentLibrary(
            folder: TextMouthPaths.rootPath,
            bookCount: libraryViewModel.library.libraryBookCount,
            feedCount: libraryViewModel.feeds.store.records.count,
            isAvailable: isAvailable,
            unsavedChanges: isAvailable ? [] : failureCenter.unsavedRows.map(\.text)
        )
    }

    // MARK: - Running Operations

    /// Runs `operation`. While it works the status line says so and the
    /// buttons are unavailable; a move shows its progress, with Cancel, in
    /// the status line's place, and announces its own steps. Afterwards the
    /// status line says what really happened, "Done" only after a success,
    /// VoiceOver announces it once, and the buttons are available again for
    /// a retry (TODO A07). A success counts only once the library's queued
    /// writes have reached the disk: while changes are left unsaved it is
    /// reported as the failure it is (TODO S09).
    private func start(_ operation: StorageOperation) {
        guard runningOperation == nil else { return }
        runningOperation = operation
        status = .running(operation)
        Task { @MainActor in
            // Rebuild Directory runs on the main actor and holds the
            // interface while it works; a move copies off it (FR02). A short
            // pause first lets the run loop draw the running status and the
            // unavailable buttons before either begins.
            await letTheStatusBeDrawn()
            let outcome = libraryViewModel.outcomeConfirmingSaves(await perform(operation))
            status = .announced(after: outcome)
            runningOperation = nil
            // The operation may have made, moved, or replaced the directory.
            directoryCheckRequest += 1
        }
    }

    /// Does the work of `operation` through the library model, which
    /// returns its outcome instead of raising an alert in the Library window.
    private func perform(_ operation: StorageOperation) async -> OperationOutcome {
        switch operation {
        case .rebuild:
            return await libraryViewModel.rebuildDirectoryReturningOutcome(waiting: showWait(of: operation))
        case .resetToDefault:
            return await libraryViewModel.rebuildToDefaultReturningOutcome()
        case .move(let destination):
            return await libraryViewModel.moveDataDirectoryReturningOutcome(to: destination)
        case .useLibrary(let folder):
            return await libraryViewModel.useLibraryReturningOutcome(at: folder)
        }
    }

    /// Redo Text Extraction: re-extracts every book's text, its progress
    /// shown meanwhile, then says what it did in the Library Maintenance
    /// section's status line, which VoiceOver hears once: "Done.", with how
    /// many books in the cloud it skipped when it left any (FR02), or, while
    /// changes are left unsaved, the failure that is (TODO S09).
    private func redoTextExtraction() {
        extractionStatus = nil
        Task { @MainActor in
            guard let outcome = await libraryViewModel.redoAllTextExtractionReturningOutcome() else { return }
            extractionStatus = .announced(after: libraryViewModel.outcomeConfirmingSaves(outcome))
        }
    }

    /// Whether a folder exists at `path`, asked through `directoryCheck` off
    /// the main thread, so a slow or missing volume never holds the
    /// interface.
    static func directoryExists(at path: String) async -> Bool {
        let check = directoryCheck
        return await Task.detached(priority: .userInitiated) { check(path) }.value
    }

    /// Pauses briefly, so the run loop draws the status line, and the
    /// buttons' state, before work that holds the interface begins.
    private func letTheStatusBeDrawn() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// What `operation`, which waits for the storage work under way before
    /// it changes anything, tells the status line: each kind of work it
    /// waits for, such as "Waiting for the current import to finish...",
    /// and its own running status again once it waits for nothing more,
    /// each announced once, as every status that changes while the user
    /// waits is. A move shows its waits in its progress instead.
    private func showWait(of operation: StorageOperation) -> (StorageWork?) async -> Void {
        { work in
            let message = work?.waitingMessage ?? operation.runningMessage
            status = StorageStatus(message: message, isFailure: false).announced()
        }
    }
}

// MARK: - Library Statistics

/// What Storage settings' Library Statistics section says, line by line,
/// each a label and a value, shown and spoken alike: the library's own books,
/// the feeds beside them where there are any (FR11), its folders, and how
/// many of its books are in packages. A feed's episodes and articles are
/// never counted as books; their feeds are counted instead.
struct LibraryStatistics: Equatable {
    /// One line: "Books" and "743".
    struct Line: Equatable, Identifiable {
        /// What the line counts.
        let label: String
        /// The count, as the line shows it.
        let value: String

        var id: String { label }
    }

    /// The lines, in the order the section shows them.
    let lines: [Line]

    /// The statistics of `library`, subscribed to `feedCount` feeds.
    init(library: Library, feedCount: Int) {
        let books = library.libraryBooks
        var lines = [Line(label: "Books", value: "\(books.count)")]
        if feedCount > 0 {
            lines.append(Line(label: "Feeds", value: "\(feedCount)"))
        }
        lines.append(Line(label: "Folders", value: "\(library.folders.count)"))
        let packaged = books.count { !$0.tmbDirectoryName.isEmpty }
        lines.append(Line(label: "TMB Packages", value: "\(packaged) of \(books.count)"))
        self.lines = lines
    }
}
