import SwiftUI

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
            return "Rebuilding the data directory..."
        case .resetToDefault:
            return "Moving data to the default location..."
        case .move(let destination):
            return "Moving data to \(destination.path)..."
        case .useLibrary(let folder):
            return "Switching to the library in \(folder.path)..."
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
        StorageStatus(message: "Checking \(folder.path)...", isFailure: false)
    }

    /// The status once an operation has finished with `outcome`: its own
    /// words, which after a failure are those of the library's error alert.
    static func finished(_ outcome: OperationOutcome) -> StorageStatus {
        StorageStatus(message: outcome.message ?? "Done.", isFailure: !outcome.succeeded)
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
    /// The button that opens the folder chooser: Change Location while the
    /// library is available, Choose Another Library while it isn't.
    static func chooserTitle(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable ? "Change Location..." : "Choose Another Library..."
    }

    /// What VoiceOver calls that button.
    static func chooserLabel(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable ? "Choose a new location for the library" : "Choose another library"
    }

    /// What that button does.
    static func chooserHint(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            ? "Opens a folder chooser. An empty folder receives a copy of the library; "
                + "a folder that holds a TextMouth library can be used as it is."
            : "Opens a folder chooser to pick a folder that holds a TextMouth library, which TextMouth then opens instead."
    }

    /// The button, shown while the library isn't available, that opens the
    /// library in the default location, or starts a new one there.
    static let useDefaultTitle = "Use Default Location..."
    /// What VoiceOver calls it.
    static let useDefaultLabel = "Use the default location"
    /// What it does.
    static let useDefaultHint = "Opens the library in the default location, ~/.TextMouth, or starts a new one there, "
        + "instead of the library that isn't available."

    /// The folder chooser's title.
    static func panelTitle(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable ? "Choose a Location for the Library" : "Choose Another Library"
    }

    /// What the folder chooser explains.
    static func panelMessage(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable
            ? "Choose an empty folder to move the library into, or a folder that holds a TextMouth library to use it. "
                + "You can make a new folder here."
            : "Choose a folder that holds a TextMouth library to use it instead."
    }

    /// The folder chooser's button, which names the action.
    static func panelPrompt(isLibraryAvailable: Bool) -> String {
        isLibraryAvailable ? "Choose Location" : "Choose Library"
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
    /// What the last data-directory operation is doing or did.
    @State private var status: StorageStatus?
    /// The data-directory operation in progress, if any.
    @State private var runningOperation: StorageOperation?
    @State private var showDuplicateFinder = false
    @State private var showRedoExtractionConfirmation = false
    /// Failed writes, so the status never says all is well while changes
    /// are unsaved (TODO S09).
    @ObservedObject private var failureCenter = PersistenceFailureCenter.shared

    /// A choice offered for a chosen folder: an alert titled `title`,
    /// explaining `message`, whose confirming `button` does `action`.
    private struct PendingConfirmation: Equatable {
        let title: String
        let message: String
        let button: String
        let action: StorageChoice.Action
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(TextMouthPaths.rootPath)
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .font(.caption)

                        if TextMouthPaths.isCustomPath {
                            Text("Custom location")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else {
                            Text("Default location")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
                .accessibilityLabel("Data directory: \(TextMouthPaths.rootPath)")

                LabeledContent("Status") {
                    Text(Self.statusText(
                        isRecoveringIndex: isRecoveringIndex,
                        directoryExists: TextMouthPaths.directoryExists,
                        hasUnsavedChanges: hasUnsavedChanges,
                        isLibraryUnavailable: unavailability != nil
                    ))
                    .foregroundColor(
                        unavailability != nil || isRecoveringIndex || hasUnsavedChanges
                            || !TextMouthPaths.directoryExists ? .red : .green
                    )
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
                    Button("Retry Saving") {
                        failureCenter.retryUnsavedChanges(announcing: true)
                    }
                    .accessibilityHint("Tries again to save every change that could not be saved")
                }

                locationButtons

                Button("Rebuild Directory") {
                    showRebuildConfirmation = true
                }
                .disabled(maintenanceUnavailable)
                .accessibilityLabel("Rebuild TextMouth directory")
                .accessibilityHint("Recreates the directory structure and migrates any books using old storage")

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
            } header: {
                Text("Storage Directory")
            }

            Section {
                Picker("After Importing a Book", selection: $settingsViewModel.importDeleteBehavior) {
                    ForEach(ImportDeleteBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.rawValue).tag(behavior)
                    }
                }
                .accessibilityLabel("Original file handling")
                .accessibilityHint("What to do with the original file after importing a book")

                // Deleting the original follows "Move to Trash instead of
                // deleting" below, so these say which it will be.
                switch settingsViewModel.importDeleteBehavior {
                case .keepOriginal:
                    Text("The original file will remain untouched after import.")
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
            } header: {
                Text("Import Behavior")
            }

            Section {
                Toggle("Confirm before removing a book", isOn: Binding(
                    get: { removal.preferences.confirmsFirst },
                    set: { removal.setConfirmsFirst($0) }
                ))
                .accessibilityHint(removalPreferences.confirmationExplanation)

                Toggle("Move to Trash instead of deleting", isOn: Binding(
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
                Text("Removal Behavior")
            }

            Section {
                LabeledContent("Books") {
                    Text("\(libraryViewModel.library.books.count)")
                }
                LabeledContent("Folders") {
                    Text("\(libraryViewModel.library.folders.count)")
                }
                let tmbCount = libraryViewModel.library.books.filter { !$0.tmbDirectoryName.isEmpty }.count
                LabeledContent("TMB Packages") {
                    Text("\(tmbCount) of \(libraryViewModel.library.books.count)")
                }
            } header: {
                Text("Library Statistics")
            }

            Section {
                Button("Find Duplicate Books...") {
                    showDuplicateFinder = true
                }
                // Removing a duplicate changes the library, which must not
                // change while it moves (FR02).
                .disabled(isMovingLibrary)
                .accessibilityLabel("Find duplicate books")
                .accessibilityHint("Scans the library for books with matching files, titles, or authors")

                Text("Search across all folders for potential duplicate books based on file content, title, or author.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Redo Text Extraction...") {
                    showRedoExtractionConfirmation = true
                }
                .disabled(libraryViewModel.isExtracting || isMovingLibrary)
                .accessibilityLabel("Redo text extraction")
                .accessibilityHint("Re-extracts cached text from all books. Useful after parser fixes or format improvements.")

                if libraryViewModel.isExtracting {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(libraryViewModel.extractionProgressCurrent),
                                     total: Double(max(libraryViewModel.extractionProgressTotal, 1)))
                            .progressViewStyle(.linear)
                        Text("\(libraryViewModel.extractionProgressCurrent)/\(libraryViewModel.extractionProgressTotal)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Text extraction progress: \(libraryViewModel.extractionProgressCurrent) of \(libraryViewModel.extractionProgressTotal)")
                } else {
                    Text("Re-extract the cached text for all books. Use this after parser updates to refresh the cached content.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Library Maintenance")
            }
        }
        .padding()
        .alert("Rebuild Directory", isPresented: $showRebuildConfirmation) {
            Button("Rebuild") {
                start(.rebuild)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will recreate the directory structure and migrate any books using old storage. Your books and reading positions will be preserved.")
        }
        .alert("Reset to Default Location?", isPresented: $showResetToDefaultConfirmation) {
            Button("Reset & Move") {
                start(.resetToDefault)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move all data from \(TextMouthPaths.rootPath) back to the default location at \(TextMouthPaths.defaultRoot.path).")
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
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("Redo Text Extraction?", isPresented: $showRedoExtractionConfirmation) {
            Button("Re-extract All") {
                libraryViewModel.redoAllTextExtraction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-extract the cached text for all books in your library. This may take a while for large libraries. Reading positions will be preserved, but character offsets may shift slightly if the extraction produces different text.")
        }
        .sheet(isPresented: $showDuplicateFinder) {
            DuplicateFinderView(libraryViewModel: libraryViewModel)
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
            } else if TextMouthPaths.isCustomPath {
                Button("Reset to Default") {
                    showResetToDefaultConfirmation = true
                }
                .disabled(maintenanceUnavailable)
                .accessibilityLabel("Reset to default location")
                .accessibilityHint("Moves data back to the default location at ~/.TextMouth")
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
        isLibraryUnavailable: Bool = false
    ) -> String {
        if isLibraryUnavailable {
            return DataDirectoryUnavailableText.title
        }
        if isRecoveringIndex {
            return LibraryIndexRecoveryText.settingsStatus
        }
        if hasUnsavedChanges {
            return "Changes not saved"
        }
        return directoryExists ? "Active" : "Not Created"
    }

    /// What the status explains while changes are unsaved: each unsaved
    /// subsystem's sentence, as the Library window's notice words it.
    nonisolated static func unsavedExplanation(_ rows: [PersistenceBannerRow]) -> String {
        rows.map(\.text).joined(separator: " ")
    }

    // MARK: - Choosing a Folder (FR02)

    /// The folder chooser Change Location and Choose Another Library open:
    /// any one folder, hidden ones shown, as this user keeps them, with a
    /// button that makes a new folder and a prompt naming the action. The
    /// chosen folder itself is the data directory; nothing is added to it.
    /// It starts in the folder holding the data directory, when that exists.
    @MainActor
    static func makeLibraryFolderPanel(isLibraryAvailable: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.title = StorageLocationWording.panelTitle(isLibraryAvailable: isLibraryAvailable)
        panel.message = StorageLocationWording.panelMessage(isLibraryAvailable: isLibraryAvailable)
        panel.prompt = StorageLocationWording.panelPrompt(isLibraryAvailable: isLibraryAvailable)
        let holder = TextMouthPaths.root.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: holder.path) {
            panel.directoryURL = holder
        }
        return panel
    }

    /// Opens the folder chooser, as a sheet on the Settings window, and
    /// looks at the folder chosen.
    private func chooseFolder() {
        let panel = Self.makeLibraryFolderPanel(isLibraryAvailable: unavailability == nil)
        let assessChosenFolder: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            assess(folder)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: assessChosenFolder)
        } else {
            panel.begin(completionHandler: assessChosenFolder)
        }
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
            isAssessing = false
            offer(StorageChoice(for: assessment, current: currentLibrary))
        }
    }

    /// Offers `choice`. A move is refused at once while a book is open,
    /// naming the books, as the move itself would refuse it.
    private func offer(_ choice: StorageChoice) {
        switch choice {
        case .confirm(let title, let message, let button, let action):
            if case .move = action, let refusal = libraryViewModel.openBooksRefusal {
                status = .announced(after: .failure("Failed to move directory", refusal))
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
            bookCount: libraryViewModel.library.books.count,
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
        }
    }

    /// Does the work of `operation` through the library model, which
    /// returns its outcome instead of raising an alert in the Library window.
    private func perform(_ operation: StorageOperation) async -> OperationOutcome {
        switch operation {
        case .rebuild:
            return libraryViewModel.rebuildDirectoryReturningOutcome()
        case .resetToDefault:
            return await libraryViewModel.rebuildToDefaultReturningOutcome()
        case .move(let destination):
            return await libraryViewModel.moveDataDirectoryReturningOutcome(to: destination)
        case .useLibrary(let folder):
            return await libraryViewModel.useLibraryReturningOutcome(at: folder)
        }
    }

    /// Pauses briefly, so the run loop draws the status line, and the
    /// buttons' state, before work that holds the interface begins.
    private func letTheStatusBeDrawn() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
