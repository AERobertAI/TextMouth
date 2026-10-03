import SwiftUI

/// A data-directory operation started from Storage settings.
enum StorageOperation: Equatable {
    /// Rebuild Directory.
    case rebuild
    /// Reset to Default: move the data back to ~/.TextMouth.
    case resetToDefault
    /// Change Location: move the data into the given directory.
    case move(to: URL)

    /// What the status line says while the operation runs.
    var runningMessage: String {
        switch self {
        case .rebuild:
            return "Rebuilding the data directory..."
        case .resetToDefault:
            return "Moving data to the default location..."
        case .move(let destination):
            return "Moving data to \(destination.path)..."
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

    /// The status while a data-directory move waits for `work` to finish
    /// before it copies anything (TODO S04), such as "Waiting for the
    /// current import to finish...".
    static func waiting(for work: StorageWork) -> StorageStatus {
        StorageStatus(message: work.waitingMessage, isFailure: false)
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
    /// user waits is: an operation's result, what a move waits for, and the
    /// move going on once it waits no more.
    @MainActor
    func announced() -> StorageStatus {
        VoiceOverAnnouncer.announce(message)
        return self
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
    @State private var showMoveConfirmation = false
    @State private var pendingMoveURL: URL?
    @State private var showFolderPicker = false
    /// What the last data-directory operation is doing or did.
    @State private var status: StorageStatus?
    /// The data-directory operation in progress, if any.
    @State private var runningOperation: StorageOperation?
    @State private var showDuplicateFinder = false
    @State private var showRedoExtractionConfirmation = false
    /// Failed writes, so the status never says all is well while changes
    /// are unsaved (TODO S09).
    @ObservedObject private var failureCenter = PersistenceFailureCenter.shared

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
                        hasUnsavedChanges: hasUnsavedChanges
                    ))
                    .foregroundColor(
                        isRecoveringIndex || hasUnsavedChanges || !TextMouthPaths.directoryExists ? .red : .green
                    )
                }

                if isRecoveringIndex {
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

                // Moving or rebuilding the directory would act on the
                // temporary library while the index cannot be read, and
                // must not start twice while one operation runs.
                HStack {
                    Button("Change Location...") {
                        showFolderPicker = true
                    }
                    .accessibilityLabel("Choose a new location for the data directory")
                    .accessibilityHint("Opens a folder picker to select where TextMouth stores its data")

                    if TextMouthPaths.isCustomPath {
                        Button("Reset to Default") {
                            showResetToDefaultConfirmation = true
                        }
                        .accessibilityLabel("Reset to default location")
                        .accessibilityHint("Moves data back to the default location at ~/.TextMouth")
                    }
                }
                .disabled(maintenanceUnavailable)

                Button("Rebuild Directory") {
                    showRebuildConfirmation = true
                }
                .disabled(maintenanceUnavailable)
                .accessibilityLabel("Rebuild TextMouth directory")
                .accessibilityHint("Recreates the directory structure and migrates any books using old storage")

                if let status {
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
                .accessibilityLabel("Find duplicate books")
                .accessibilityHint("Scans the library for books with matching files, titles, or authors")

                Text("Search across all folders for potential duplicate books based on file content, title, or author.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Redo Text Extraction...") {
                    showRedoExtractionConfirmation = true
                }
                .disabled(libraryViewModel.isExtracting)
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
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // The user picked a parent folder — we'll put .TextMouth inside it
                    let target = url.appendingPathComponent(".TextMouth", isDirectory: true)
                    pendingMoveURL = target
                    showMoveConfirmation = true
                }
            case .failure(let error):
                status = .announced(after: .failure("Could not choose a new location", error))
            }
        }
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
        .alert("Move Data Directory?", isPresented: $showMoveConfirmation) {
            Button("Move") {
                if let url = pendingMoveURL {
                    pendingMoveURL = nil
                    start(.move(to: url))
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMoveURL = nil
            }
        } message: {
            if let url = pendingMoveURL {
                Text("Copy all TextMouth data to \(url.path), validate it, and use the new location? The current directory will be retained as recovery data.")
            }
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

    /// Whether the library index could not be read and is being recovered.
    private var isRecoveringIndex: Bool {
        libraryViewModel.indexRecovery != nil
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

    /// Whether the location and rebuild buttons are unavailable right now.
    private var maintenanceUnavailable: Bool {
        Self.maintenanceUnavailable(isRecoveringIndex: isRecoveringIndex, isRunning: runningOperation != nil)
    }

    /// Whether the location and rebuild buttons are unavailable: while the
    /// library index cannot be read, since they would act on the temporary
    /// library, and while one of them runs. Once an operation ends, whether
    /// it worked or failed, they are available again, so a failure can be
    /// retried.
    nonisolated static func maintenanceUnavailable(isRecoveringIndex: Bool, isRunning: Bool) -> Bool {
        isRecoveringIndex || isRunning
    }

    /// The data directory status, as shown and as VoiceOver reads it. An
    /// unreadable library index outranks "Active": the directory exists, but
    /// its library index is not being saved. So do unsaved changes (TODO
    /// S09): a directory whose writes fail is not working as it should.
    nonisolated static func statusText(
        isRecoveringIndex: Bool,
        directoryExists: Bool,
        hasUnsavedChanges: Bool = false
    ) -> String {
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

    // MARK: - Running Operations

    /// Runs `operation`. While it works the status line says so and the
    /// buttons are unavailable; afterwards the status line says what really
    /// happened, "Done" only after a success, VoiceOver announces it once,
    /// and the buttons are available again for a retry (TODO A07). A success
    /// counts only once the library's queued writes have reached the disk:
    /// while changes are left unsaved it is reported as the failure it is
    /// (TODO S09).
    private func start(_ operation: StorageOperation) {
        guard runningOperation == nil else { return }
        runningOperation = operation
        status = .running(operation)
        Task { @MainActor in
            // The work runs on the main actor and holds the interface while
            // it copies. A short pause first lets the run loop draw the
            // running status and the unavailable buttons before it begins.
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
            return await libraryViewModel.rebuildToDefaultReturningOutcome { work in
                await showWaiting(for: work, during: operation)
            }
        case .move(let destination):
            return await libraryViewModel.moveDataDirectoryReturningOutcome(to: destination) { work in
                await showWaiting(for: work, during: operation)
            }
        }
    }

    /// Shows, and announces once, what a move waits for before it copies
    /// anything, such as the import under way (TODO S04); with nil, the
    /// move waits no more, and the status line says it is moving again,
    /// drawn before the copy holds the interface.
    private func showWaiting(for work: StorageWork?, during operation: StorageOperation) async {
        guard let work else {
            status = StorageStatus.running(operation).announced()
            await letTheStatusBeDrawn()
            return
        }
        status = StorageStatus.waiting(for: work).announced()
    }

    /// Pauses briefly, so the run loop draws the status line, and the
    /// buttons' state, before work that holds the interface begins.
    private func letTheStatusBeDrawn() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
